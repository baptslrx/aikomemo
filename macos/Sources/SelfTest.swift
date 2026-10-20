import AppKit
import SwiftUI

/// `AikoMemo --selftest <dossier>` : vérifie la vraie appli (dossier surveillé, presse-papiers, recherche)
/// sans toucher à la mémoire de l'utilisateur, puis enregistre des captures de l'interface.
@MainActor
final class SelfTest {
    let outDir: URL
    private var failures: [String] = []
    private var report: [String] = []
    private let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

    init(outDir: URL) {
        self.outDir = outDir
    }

    func run() {
        Task { @MainActor in
            await steps()
            finish()
        }
        // Filet de sécurité : jamais plus de 3 minutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { [weak self] in
            MainActor.assumeIsolated {
                self?.check(false, "le test a dépassé 3 minutes")
                self?.finish()
            }
        }
    }

    private func log(_ s: String) {
        print(s)
        fflush(stdout)
        report.append(s)
    }

    private func check(_ ok: Bool, _ what: String) {
        log((ok ? "  ok   " : "  FAIL ") + what)
        if !ok {
            failures.append(what)
            if ci { print("::error title=Test::\(what)") }
        }
    }

    private func sleep(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
    }

    private func steps() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        // Chemin réel (/private/var/…), comme le rapporte FSEvents
        let base = realpath(fm.temporaryDirectory.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) }
            ?? fm.temporaryDirectory.path
        let tmp = URL(fileURLWithPath: base).appendingPathComponent("aikomemo-selftest-\(UUID().uuidString)")
        let watch = tmp.appendingPathComponent("Projets clients")
        try? fm.createDirectory(at: watch.appendingPathComponent("node_modules"), withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "fr.aikographic.aikomemo.selftest")!
        defaults.removePersistentDomain(forName: "fr.aikographic.aikomemo.selftest")
        let settings = MemoSettings(defaults: defaults, persist: false)
        settings.folders = [watch.path]
        settings.excludedApps = []
        let store: Store
        do {
            store = try Store(url: tmp.appendingPathComponent("memoire.sqlite"))
        } catch {
            check(false, "ouverture de la base : \(error)")
            return
        }
        check(store.hasFTS, "recherche plein texte disponible")
        let recorder = Recorder(store: store, settings: settings, clipsDir: tmp.appendingPathComponent("copies"))
        recorder.start()
        await sleep(2)

        log("== Fichiers")
        let devis = watch.appendingPathComponent("Devis_Client_Nike.pdf")
        try? Data("%PDF-1.4 devis".utf8).write(to: devis)
        let facture = watch.appendingPathComponent("Facture_Octobre.pdf")
        try? Data("%PDF-1.4 facture".utf8).write(to: facture)
        setXattr(facture.path, "com.apple.metadata:kMDItemWhereFroms",
                 try! PropertyListSerialization.data(fromPropertyList: [
                     "https://mail-attachment.googleusercontent.com/attachment/u/0/?ui=2", "https://mail.google.com/",
                 ], format: .binary, options: 0))
        setXattr(facture.path, "com.apple.quarantine", Data("0083;6720f000;Google Chrome;".utf8))
        let airdrop = watch.appendingPathComponent("IMG_4821.HEIC")
        try? Data([0, 1, 2, 3]).write(to: airdrop)
        setXattr(airdrop.path, "com.apple.quarantine", Data("0083;6720f000;sharingd;".utf8))
        try? Data("x".utf8).write(to: watch.appendingPathComponent(".DS_Store"))
        try? Data("x".utf8).write(to: watch.appendingPathComponent("rush.mov.crdownload"))
        try? Data("x".utf8).write(to: watch.appendingPathComponent("node_modules/index.js"))
        await sleep(6)

        var all = store.search(ParsedQuery(), limit: 100)
        log("   enregistré : " + all.map { "\($0.kind.rawValue) \($0.title) \($0.source ?? "")" }.joined(separator: " | "))
        check(all.contains { $0.kind == .created && $0.title == devis.lastPathComponent }, "fichier créé repéré")
        check(all.contains { $0.kind == .download && $0.title == facture.lastPathComponent && $0.source == "Gmail" },
              "téléchargement + origine Gmail")
        check(all.contains { $0.kind == .download && $0.title == airdrop.lastPathComponent && $0.source == "AirDrop" },
              "réception AirDrop")
        check(!all.contains { $0.title == ".DS_Store" || $0.title.hasSuffix(".crdownload") || $0.title == "index.js" },
              "fichiers cachés, temporaires et node_modules ignorés")

        if let h = try? FileHandle(forWritingTo: devis) {
            h.seekToEndOfFile()
            h.write(Data(" v2".utf8))
            try? h.close()
        }
        await sleep(3)
        all = store.search(ParsedQuery(), limit: 100)
        check(all.filter { $0.path == devis.path }.count == 1, "modification juste après : pas de doublon")

        log("== Presse-papiers")
        let pb = NSPasteboard.general
        func copy(_ s: String, concealed: Bool = false) {
            pb.clearContents()
            if concealed {
                let t = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
                pb.declareTypes([.string, t], owner: nil)
                pb.setString("", forType: t)
            }
            pb.setString(s, forType: .string)
            recorder.pollClipboard()
        }
        copy("Rendez-vous lundi 10h chez Studio Lumière, 12 rue des Arts")
        copy("SuperSecret!42", concealed: true)
        copy("Xk9#mP2$vL7q")
        copy("https://www.figma.com/file/abc123/Logo-Studio-Lumiere")
        pb.clearContents()
        pb.writeObjects([Self.sampleImage()])
        recorder.pollClipboard()
        all = store.search(ParsedQuery(), limit: 100)
        let clips = all.filter { $0.kind == .clipboard }
        log("   copies : " + clips.map(\.title).joined(separator: " | "))
        check(clips.contains { $0.title.hasPrefix("Rendez-vous lundi") }, "texte copié enregistré")
        check(clips.contains { $0.detail?.hasPrefix("https://www.figma.com") == true }, "lien copié enregistré")
        check(clips.contains { $0.detail?.hasPrefix("image:") == true }, "image copiée enregistrée (miniature)")
        check(!all.contains { ($0.detail ?? "").contains("SuperSecret") || $0.title.contains("SuperSecret") },
              "mot de passe d'un gestionnaire jamais enregistré")
        check(!all.contains { ($0.detail ?? "").contains("Xk9#mP2") }, "texte qui ressemble à un mot de passe ignoré")

        // Une séance Figma juste après la copie du lien
        store.insert(MemoEvent(ts: Date().addingTimeInterval(30), kind: .app, title: "Figma", detail: "com.figma.Desktop",
                               duration: 900))
        store.insert(MemoEvent(ts: Date().addingTimeInterval(-3 * 86400), kind: .download, title: "Brief_Lumière.pdf",
                               path: "/Users/test/Downloads/Brief_Lumière.pdf", source: "WeTransfer", ext: "pdf"))

        log("== Recherche")
        let model = SearchModel(store: store)
        func titles(_ q: String) -> [String] {
            model.text = q
            model.refresh()
            return model.results.map(\.title)
        }
        var r = titles("le pdf téléchargé depuis Gmail")
        check(r == ["Facture_Octobre.pdf"], "« le pdf téléchargé depuis Gmail » → \(r)")
        r = titles("devis nike")
        check(r == ["Devis_Client_Nike.pdf"], "« devis nike » → \(r)")
        r = titles("la photo que j'ai reçue par AirDrop")
        check(r == ["IMG_4821.HEIC"], "« la photo que j'ai reçue par AirDrop » → \(r)")
        r = titles("le lien copié avant d'ouvrir Figma")
        check(r.count == 1 && r[0].contains("figma.com"), "« le lien copié avant d'ouvrir Figma » → \(r)")
        r = titles("studio lumiere")
        check(r.contains { $0.hasPrefix("Rendez-vous") }, "accents ignorés : « studio lumiere » → \(r)")
        r = titles("brief il y a 3 jours")
        check(r == ["Brief_Lumière.pdf"], "« brief il y a 3 jours » → \(r)")
        r = titles("supersecret")
        check(r.isEmpty, "aucune trace du mot de passe")

        recorder.stop()

        log("== Captures")
        for dark in [true, false] {
            let suffix = dark ? "sombre" : "clair"
            model.text = "le pdf téléchargé depuis Gmail"
            model.refresh()
            await snapshot(SearchView(model: model, onActivate: { _ in }, onReveal: { _ in }, onSettings: {}),
                           size: NSSize(width: 720, height: 520), dark: dark, name: "recherche-\(suffix).png")
            model.text = ""
            model.refresh()
            await snapshot(SearchView(model: model, onActivate: { _ in }, onReveal: { _ in }, onSettings: {}),
                           size: NSSize(width: 720, height: 520), dark: dark, name: "chronologie-\(suffix).png")
            model.text = "facture de mars depuis dropbox"
            model.refresh()
            await snapshot(SearchView(model: model, onActivate: { _ in }, onReveal: { _ in }, onSettings: {}),
                           size: NSSize(width: 720, height: 520), dark: dark, name: "aucun-resultat-\(suffix).png")
            await snapshot(SettingsView(settings: settings, stats: { "42 souvenirs · 96 Ko sur ton Mac" },
                                        onShortcut: {}, onFoldersChanged: {}, onPause: { _ in }, onEraseAll: {}),
                           size: NSSize(width: 460, height: 660), dark: dark, name: "reglages-\(suffix).png")
        }
        try? fm.removeItem(at: tmp)
    }

    private func setXattr(_ path: String, _ name: String, _ data: Data) {
        _ = data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, 0) }
    }

    static func sampleImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 320, height: 200))
        img.lockFocus()
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 110, y: 50, width: 100, height: 100)).fill()
        img.unlockFocus()
        return img
    }

    private func snapshot<V: View>(_ view: V, size: NSSize, dark: Bool, name: String) async {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: NSRect(x: 40, y: 40, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.backgroundColor = dark ? .black : .white
        w.contentView = host
        w.orderFrontRegardless()
        await sleep(0.8)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
            log("   \(name)")
        } else {
            check(false, "capture \(name)")
        }
        w.orderOut(nil)
    }

    private var finished = false
    private func finish() {
        guard !finished else { return }
        finished = true
        log(failures.isEmpty ? "\nTout est OK" : "\nÉCHECS :\n" + failures.joined(separator: "\n"))
        try? report.joined(separator: "\n").write(to: outDir.appendingPathComponent("rapport.txt"),
                                                  atomically: true, encoding: .utf8)
        exit(failures.isEmpty ? 0 : 1)
    }
}
