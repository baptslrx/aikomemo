import AppKit
import ServiceManagement

struct AppRef: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

@MainActor
final class MemoSettings: ObservableObject {
    static let defaultShortcut = Shortcut(keyCode: 46, carbonModifiers: 6144, label: "⌃ ⌥ M")  // kVK_ANSI_M + ⌃⌥

    /// Jamais rien d'enregistré pendant qu'elles sont au premier plan (et le presse-papiers les ignore).
    static let alwaysExcluded: [AppRef] = [
        AppRef(bundleID: "com.apple.Passwords", name: "Mots de passe"),
        AppRef(bundleID: "com.apple.keychainaccess", name: "Trousseau d'accès"),
        AppRef(bundleID: "com.1password.1password", name: "1Password"),
        AppRef(bundleID: "com.agilebits.onepassword7", name: "1Password 7"),
        AppRef(bundleID: "com.bitwarden.desktop", name: "Bitwarden"),
        AppRef(bundleID: "com.dashlane.dashlanephonefinal", name: "Dashlane"),
        AppRef(bundleID: "com.lastpass.lastpassmacdesktop", name: "LastPass"),
        AppRef(bundleID: "in.sinew.Enpass-Desktop", name: "Enpass"),
        AppRef(bundleID: "org.keepassxc.keepassxc", name: "KeePassXC"),
        AppRef(bundleID: "com.proton.pass.electron", name: "Proton Pass"),
    ]

    static var defaultFolders: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
    }

    private let d: UserDefaults
    private let persist: Bool

    @Published var recordApps: Bool { didSet { save(recordApps, "recordApps") } }
    @Published var recordClipboard: Bool { didSet { save(recordClipboard, "recordClipboard") } }
    @Published var recordDownloads: Bool { didSet { save(recordDownloads, "recordDownloads") } }
    @Published var recordFiles: Bool { didSet { save(recordFiles, "recordFiles") } }
    @Published var folders: [String] { didSet { save(folders, "folders") } }
    @Published var excludedApps: [AppRef] {
        didSet { if persist, let data = try? JSONEncoder().encode(excludedApps) { d.set(data, forKey: "excludedApps") } }
    }
    @Published var retentionDays: Int { didSet { save(retentionDays, "retentionDays") } }
    @Published var pausedUntil: Date? { didSet { save(pausedUntil, "pausedUntil") } }
    @Published var shortcut: Shortcut {
        didSet { if persist, let data = try? JSONEncoder().encode(shortcut) { d.set(data, forKey: "shortcut") } }
    }
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    init(defaults: UserDefaults = .standard, persist: Bool = true) {
        d = defaults
        self.persist = persist
        recordApps = d.object(forKey: "recordApps") as? Bool ?? true
        recordClipboard = d.object(forKey: "recordClipboard") as? Bool ?? true
        recordDownloads = d.object(forKey: "recordDownloads") as? Bool ?? true
        recordFiles = d.object(forKey: "recordFiles") as? Bool ?? true
        folders = d.stringArray(forKey: "folders") ?? Self.defaultFolders
        if let data = d.data(forKey: "excludedApps"), let list = try? JSONDecoder().decode([AppRef].self, from: data) {
            excludedApps = list
        } else {
            excludedApps = []
        }
        retentionDays = d.object(forKey: "retentionDays") as? Int ?? 30
        pausedUntil = d.object(forKey: "pausedUntil") as? Date
        if let data = d.data(forKey: "shortcut"), let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
            shortcut = s
        } else {
            shortcut = Self.defaultShortcut
        }
    }

    private func save(_ value: Any?, _ key: String) {
        guard persist else { return }
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date()
    }

    var excludedBundleIDs: Set<String> {
        Set(excludedApps.map(\.bundleID) + Self.alwaysExcluded.map(\.bundleID))
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
