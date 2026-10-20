import AppKit
import SwiftUI

@main
@MainActor
struct AikoMemoMain {
    static func main() {
        let app = NSApplication.shared
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let out = i + 1 < args.count ? args[i + 1] : "screenshots"
            let test = SelfTest(outDir: URL(fileURLWithPath: out))
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.async { test.run() }
            app.run()
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var settings: MemoSettings!
    private var store: Store!
    private var recorder: Recorder!
    private var search: SearchPanel!
    private var statusItem: NSStatusItem!
    private var hotkey: GlobalHotKey!
    private var shortcutRecorder: ShortcutRecorder!
    private var settingsWindow: NSWindow?

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AikoMemo", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        settings = MemoSettings()
        do {
            store = try Store(url: Self.supportDir.appendingPathComponent("memoire.sqlite"))
        } catch {
            let alert = NSAlert()
            alert.messageText = "AikoMemo n'arrive pas à ouvrir sa mémoire"
            alert.informativeText = "\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        recorder = Recorder(store: store, settings: settings, clipsDir: Self.supportDir.appendingPathComponent("copies"))
        search = SearchPanel(model: SearchModel(store: store))
        search.recorder = recorder
        search.onSettings = { [weak self] in self?.openSettings() }
        recorder.onChange = { [weak self] in
            guard let self, self.search.isVisible else { return }
            self.search.model.schedule()
        }
        recorder.start()

        hotkey = GlobalHotKey(signature: OSType(0x414B_4D4D)) { [weak self] in  // « AKMM »
            MainActor.assumeIsolated { self?.search.toggle() }
        }
        hotkey.register(settings.shortcut)
        shortcutRecorder = ShortcutRecorder(appName: "AikoMemo", purpose: "ouvre la recherche",
                                            fallback: MemoSettings.defaultShortcut)
        shortcutRecorder.onSave = { [weak self] s in self?.settings.shortcut = s }
        shortcutRecorder.onClose = { [weak self] in
            guard let self else { return }
            self.hotkey.register(self.settings.shortcut)
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        if !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showWelcome()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder?.stop()
    }

    private func updateIcon() {
        let paused = settings.isPaused
        let img = NSImage(systemSymbolName: paused ? "pause.circle" : "sparkle.magnifyingglass",
                          accessibilityDescription: "AikoMemo")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.toolTip = paused ? "AikoMemo — en pause" : "AikoMemo — \(settings.shortcut.label) pour chercher"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let searchItem = NSMenuItem(title: "Rechercher…", action: #selector(openSearch), keyEquivalent: "")
        searchItem.target = self
        let s = NSMutableAttributedString(string: "Rechercher…")
        s.append(NSAttributedString(string: "    " + settings.shortcut.label,
                                    attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        searchItem.attributedTitle = s
        menu.addItem(searchItem)
        menu.addItem(.separator())
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        if settings.isPaused, let until = settings.pausedUntil {
            status.title = "En pause jusqu'à \(until.formatted(date: .omitted, time: .shortened))"
            menu.addItem(status)
            menu.addItem(item("Reprendre", #selector(resume)))
        } else {
            status.title = "Mémoire active · \(store.count()) souvenirs"
            menu.addItem(status)
            menu.addItem(item("Pause 1 heure", #selector(pauseHour)))
            menu.addItem(item("Pause jusqu'à demain", #selector(pauseTomorrow)))
        }
        menu.addItem(.separator())
        menu.addItem(item("Réglages…", #selector(openSettings)))
        menu.addItem(item("Quitter AikoMemo", #selector(quit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        return it
    }

    @objc private func openSearch() { search.show() }
    @objc private func pauseHour() { pause(3600) }
    @objc private func pauseTomorrow() { pause(-1) }
    @objc private func resume() { pause(nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    private func pause(_ seconds: TimeInterval?) {
        if let seconds {
            if seconds < 0 {
                let cal = Calendar.current
                let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
                settings.pausedUntil = cal.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow)
            } else {
                settings.pausedUntil = Date().addingTimeInterval(seconds)
            }
        } else {
            settings.pausedUntil = nil
        }
        updateIcon()
        if let until = settings.pausedUntil {
            DispatchQueue.main.asyncAfter(deadline: .now() + until.timeIntervalSinceNow + 1) { [weak self] in
                MainActor.assumeIsolated { self?.updateIcon() }
            }
        }
    }

    // MARK: Fenêtres

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = settingsWindow { w.makeKeyAndOrderFront(nil); return }
        let view = SettingsView(
            settings: settings,
            stats: { [weak self] in
                guard let self else { return "" }
                let n = self.store.count()
                let bytes = (try? FileManager.default.attributesOfItem(atPath: self.store.url.path)[.size] as? Int) ?? 0
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                return "\(n) souvenirs · \(size) sur ton Mac"
            },
            onShortcut: { [weak self] in
                guard let self else { return }
                self.hotkey.unregister()
                self.shortcutRecorder.open(current: self.settings.shortcut)
            },
            onFoldersChanged: { [weak self] in self?.recorder.restartFileWatching() },
            onPause: { [weak self] s in self?.pause(s) },
            onEraseAll: { [weak self] in self?.recorder.eraseAll() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Réglages AikoMemo"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.isReleasedWhenClosed = false
        w.center()
        settingsWindow = w
        w.makeKeyAndOrderFront(nil)
    }

    private func showWelcome() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "AikoMemo commence à se souvenir"
        alert.informativeText = """
        À partir de maintenant, AikoMemo retient les applis que tu utilises, ce que tu copies, tes téléchargements \
        (et d'où ils viennent) et les fichiers que tu crées ou ouvres. Tout reste sur ton Mac, les mots de passe ne \
        sont jamais enregistrés.

        Appuie sur \(settings.shortcut.label) et écris comme tu parles : « le pdf reçu sur WhatsApp hier ».

        macOS va te demander l'accès au Bureau, aux Documents et aux Téléchargements : clique sur Autoriser.
        """
        alert.addButton(withTitle: "Compris")
        alert.runModal()
    }
}
