import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: MemoSettings
    var stats: () -> String
    var onShortcut: () -> Void
    var onFoldersChanged: () -> Void
    var onPause: (TimeInterval?) -> Void
    var onEraseAll: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var statsText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accentText(scheme))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AikoMemo").font(.system(size: 20, weight: .semibold))
                        Text("La mémoire de ton Mac — tout reste sur ton Mac").font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                section("Ce que retient AikoMemo") {
                    toggle("Applis utilisées", "Quelle appli, quand, combien de temps", $settings.recordApps)
                    toggle("Presse-papiers", "Textes, liens, images et fichiers copiés — jamais les mots de passe",
                           $settings.recordClipboard)
                    toggle("Téléchargements", "Avec leur origine : Gmail, WhatsApp, AirDrop, WeTransfer…",
                           $settings.recordDownloads, changed: onFoldersChanged)
                    toggle("Fichiers", "Créés, modifiés et ouverts dans les dossiers ci-dessous",
                           $settings.recordFiles, changed: onFoldersChanged)
                }

                section("Dossiers surveillés") {
                    ForEach(settings.folders, id: \.self) { folder in
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: folder)).resizable().frame(width: 18, height: 18)
                            Text(prettyPath(folder)).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                settings.folders.removeAll { $0 == folder }
                                onFoldersChanged()
                            } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        Button("Ajouter un dossier…") { addFolder() }
                        Text("(un disque de rushs, un dossier de projets…)").font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                section("Jamais pendant que j'utilise") {
                    Text("Ni appli, ni presse-papiers enregistrés quand ces applis sont au premier plan. "
                         + "Les gestionnaires de mots de passe sont toujours exclus.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(settings.excludedApps) { app in
                        HStack {
                            appIcon(app.bundleID)
                            Text(app.name).font(.system(size: 13))
                            Spacer()
                            Button { settings.excludedApps.removeAll { $0 == app } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    Button("Ajouter une app…") { addApp() }
                }

                section("Durée de la mémoire") {
                    Picker("", selection: $settings.retentionDays) {
                        Text("7 jours").tag(7)
                        Text("30 jours").tag(30)
                        Text("3 mois").tag(90)
                        Text("1 an").tag(365)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(statsText).font(.system(size: 11)).foregroundStyle(.secondary)
                }

                section("Pause") {
                    if settings.isPaused, let until = settings.pausedUntil {
                        HStack {
                            Text("En pause jusqu'à \(until.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 13))
                            Spacer()
                            Button("Reprendre") { onPause(nil) }
                        }
                    } else {
                        HStack {
                            Button("Pause 1 heure") { onPause(3600) }
                            Button("Jusqu'à demain") { onPause(-1) }
                        }
                    }
                }

                section("Général") {
                    HStack {
                        Text("Raccourci de recherche")
                        Spacer()
                        Button(settings.shortcut.label) { onShortcut() }
                    }
                    Toggle("Ouvrir au démarrage du Mac",
                           isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch).tint(Theme.accentUI)
                    Button("Tout effacer…", role: .destructive) { confirmErase() }
                }
            }
            .padding(22)
        }
        .frame(width: 460, height: 660)
        .background(Theme.background(scheme))
        .onAppear { statsText = stats() }
    }

    private func toggle(_ title: String, _ detail: String, _ value: Binding<Bool>,
                        changed: (() -> Void)? = nil) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; changed?() })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accentUI)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.accentText(scheme))
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface(scheme)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line(scheme)))
        }
    }

    private func prettyPath(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.replacingOccurrences(of: home, with: "~")
    }

    private func appIcon(_ bundleID: String) -> some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let img = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage()
        return Image(nsImage: img).resizable().frame(width: 18, height: 18)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Surveiller"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.folders.contains(url.path) { settings.folders.append(url.path) }
        onFoldersChanged()
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.prompt = "Exclure"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier,
                  !settings.excludedApps.contains(where: { $0.bundleID == id }) else { continue }
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            settings.excludedApps.append(AppRef(bundleID: id, name: name))
        }
    }

    private func confirmErase() {
        let alert = NSAlert()
        alert.messageText = "Tout effacer ?"
        alert.informativeText = "Toute la mémoire d'AikoMemo sera supprimée. Tes fichiers, eux, ne sont pas touchés."
        alert.addButton(withTitle: "Tout effacer")
        alert.addButton(withTitle: "Annuler")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn {
            onEraseAll()
            statsText = stats()
        }
    }
}
