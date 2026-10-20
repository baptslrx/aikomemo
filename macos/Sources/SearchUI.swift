import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Modèle de la recherche

@MainActor
final class SearchModel: ObservableObject {
    @Published var text = "" { didSet { schedule() } }
    @Published private(set) var results: [MemoEvent] = []
    @Published private(set) var parsed = ParsedQuery()
    @Published var selection: Int64?
    @Published var paused = false

    let store: Store
    var now: () -> Date = { Date() }
    private var pending: DispatchWorkItem?

    init(store: Store) {
        self.store = store
    }

    func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func refresh() {
        let parser = QueryParser(now: now(), knownApps: store.appNames())
        parsed = parser.parse(text)
        results = store.search(parsed, limit: 200)
        if selection == nil || !results.contains(where: { $0.id == selection }) {
            selection = results.first?.id
        }
    }

    struct Day: Identifiable {
        let id: Date
        let label: String
        let items: [MemoEvent]
    }

    var days: [Day] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [MemoEvent]] = [:]
        for e in results {
            let d = cal.startOfDay(for: e.ts)
            if buckets[d] == nil { order.append(d) }
            buckets[d, default: []].append(e)
        }
        return order.map { Day(id: $0, label: Self.dayLabel($0, now: now()), items: buckets[$0] ?? []) }
    }

    static func dayLabel(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        if d == today { return "Aujourd'hui" }
        if d == cal.date(byAdding: .day, value: -1, to: today) { return "Hier" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = cal.isDate(d, equalTo: now, toGranularity: .year) ? "EEEE d MMMM" : "EEEE d MMMM yyyy"
        let s = f.string(from: d)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    func move(_ delta: Int) {
        let flat = results
        guard !flat.isEmpty else { return }
        let i = flat.firstIndex(where: { $0.id == selection }) ?? -1
        let n = max(0, min(flat.count - 1, i + delta))
        selection = flat[n].id
    }

    var selected: MemoEvent? { results.first { $0.id == selection } }
}

// MARK: - Actions sur un souvenir

@MainActor
enum Actions {
    static func open(_ e: MemoEvent, recorder: Recorder?) -> String? {
        switch e.kind {
        case .clipboard:
            copy(e, recorder: recorder)
            return "Recopié dans le presse-papiers"
        case .app:
            if let id = e.detail, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: .init())
            }
            return nil
        default:
            guard let path = e.path else { return nil }
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                return nil
            }
            if let folder = e.folder, FileManager.default.fileExists(atPath: folder) {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder))
            }
            return "Ce fichier a été déplacé ou supprimé"
        }
    }

    static func reveal(_ e: MemoEvent) {
        if let path = e.path, FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else if let detail = e.detail, detail.hasPrefix("image:") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: String(detail.dropFirst(6)))])
        } else if let folder = e.folder {
            NSWorkspace.shared.open(URL(fileURLWithPath: folder))
        }
    }

    static func copy(_ e: MemoEvent, recorder: Recorder?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let detail = e.detail, detail.hasPrefix("image:"), let img = NSImage(contentsOfFile: String(detail.dropFirst(6))) {
            pb.writeObjects([img])
        } else if e.kind == .clipboard, let text = e.detail, e.path == nil {
            pb.setString(text, forType: .string)
        } else if let path = e.path {
            pb.writeObjects([URL(fileURLWithPath: path) as NSURL])
        } else {
            pb.setString(e.detail ?? e.title, forType: .string)
        }
        recorder?.ignoreCurrentClipboard()
    }
}

// MARK: - Vue de recherche

struct SearchView: View {
    @ObservedObject var model: SearchModel
    var onActivate: (MemoEvent) -> Void
    var onReveal: (MemoEvent) -> Void
    var onSettings: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    static let examples = [
        "le pdf que j'ai téléchargé depuis Gmail hier",
        "le lien copié avant d'ouvrir Figma",
        "la vidéo reçue par AirDrop la semaine dernière",
        "ce que j'ai copié il y a 2 heures",
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.accentText(scheme))
                TextField("Retrouve n'importe quoi…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22))
                    .focused($focused)
                if !model.text.isEmpty {
                    Button { model.text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, model.parsed.isEmpty ? 16 : 10)

            if !model.parsed.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(model.parsed.chips, id: \.self) { chip in
                            HStack(spacing: 5) {
                                Image(systemName: chip.symbol).font(.system(size: 10, weight: .semibold))
                                Text(chip.text).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .foregroundStyle(Theme.accentText(scheme))
                            .background(Capsule().fill(Theme.accentUI.opacity(scheme == .dark ? 0.14 : 0.16)))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 12)
            }

            Rectangle().fill(Theme.line(scheme)).frame(height: 1)

            if model.results.isEmpty {
                empty
            } else {
                list
            }

            Rectangle().fill(Theme.line(scheme)).frame(height: 1)
            footer
        }
        .frame(width: 720, height: 520)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.background(scheme)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line(scheme)))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { focused = true }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.days) { day in
                        Section {
                            ForEach(day.items) { e in
                                ResultRow(event: e, selected: e.id == model.selection)
                                    .id(e.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) { onActivate(e) }
                                    .onTapGesture { model.selection = e.id }
                            }
                        } header: {
                            Text(day.label.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accentText(scheme))
                                .padding(.horizontal, 20)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.background(scheme))
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selection) { id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text.isEmpty ? "La mémoire se remplit au fil de ta journée." : "Rien trouvé pour l'instant.")
                .font(.system(size: 14, weight: .medium))
            Text("Essaie par exemple :").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(Self.examples, id: \.self) { ex in
                Button { model.text = ex } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right").font(.system(size: 10))
                        Text(ex).font(.system(size: 13))
                    }
                    .foregroundStyle(Theme.accentText(scheme))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", "Ouvrir")
            hint("⌘ ↩", "Afficher")
            hint("⌘ C", "Copier")
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.paused ? Color.orange : Theme.accentUI).frame(width: 6, height: 6)
                Text(model.paused ? "En pause" : "Mémoire active").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { onSettings() } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Réglages")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.surface(scheme)))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

struct ResultRow: View {
    let event: MemoEvent
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.time.string(from: event.ts))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Theme.accentUI.opacity(scheme == .dark ? 0.18 : 0.20) : Color.clear))
        .padding(.horizontal, 8)
    }

    var subtitle: String {
        var parts: [String] = []
        switch event.kind {
        case .download:
            parts.append("Téléchargé" + (event.source.map { " depuis \($0)" } ?? ""))
        case .clipboard:
            parts.append("Copié" + (event.source.map { " dans \($0)" } ?? ""))
        case .app:
            let m = Int(event.duration / 60)
            parts.append("Utilisé" + (m > 0 ? " \(m) min" : ""))
        default:
            parts.append(event.kind.verb + (event.app.map { " · \($0)" } ?? ""))
        }
        if let folder = event.folder, event.kind != .clipboard {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            parts.append(folder.replacingOccurrences(of: home, with: "~"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var icon: some View {
        if let detail = event.detail, detail.hasPrefix("image:"),
           let img = NSImage(contentsOfFile: String(detail.dropFirst(6))) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 6))
        } else if event.kind == .app, let id = event.detail,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable()
        } else if let path = event.path, event.kind != .clipboard || FileManager.default.fileExists(atPath: path) {
            Image(nsImage: FileIcons.icon(path: path, ext: event.ext)).resizable()
        } else {
            Image(systemName: event.detail?.hasPrefix("http") == true ? "link" : event.kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accentText(scheme))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accentUI.opacity(0.14)))
        }
    }
}

@MainActor
enum FileIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(path: String, ext: String?) -> NSImage {
        if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        let key = ext ?? ""
        if let i = cache[key] { return i }
        let i: NSImage
        if let ext, let type = UTType(filenameExtension: ext) {
            i = NSWorkspace.shared.icon(for: type)
        } else {
            i = NSWorkspace.shared.icon(for: .data)
        }
        cache[key] = i
        return i
    }
}

// MARK: - Fenêtre flottante (comme Spotlight)

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class SearchPanel: NSObject, NSWindowDelegate {
    let model: SearchModel
    weak var recorder: Recorder?
    var onSettings: (() -> Void)?
    private var panel: KeyPanel?
    private var monitor: Any?

    init(model: SearchModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        let p = panel ?? makePanel()
        panel = p
        model.paused = recorder?.settings.isPaused ?? false
        model.refresh()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 360, y: f.minY + f.height * 0.62 - 260))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func makePanel() -> KeyPanel {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        let view = SearchView(model: model,
                              onActivate: { [weak self] e in self?.activate(e) },
                              onReveal: { [weak self] e in self?.hide(); Actions.reveal(e) },
                              onSettings: { [weak self] in self?.hide(); self?.onSettings?() })
        p.contentView = NSHostingView(rootView: view)
        return p
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private func activate(_ e: MemoEvent) {
        hide()
        if let message = Actions.open(e, recorder: recorder) { Toast.shared.show(message) }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape:
            hide()
            return nil
        case kVK_DownArrow:
            model.move(1)
            return nil
        case kVK_UpArrow:
            model.move(-1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard let e = model.selected else { return nil }
            if cmd { hide(); Actions.reveal(e) } else { activate(e) }
            return nil
        case kVK_ANSI_C where cmd:
            let editor = panel?.firstResponder as? NSTextView
            if let e = model.selected, (editor?.selectedRange().length ?? 0) == 0 {
                Actions.copy(e, recorder: recorder)
                hide()
                Toast.shared.show("Copié")
                return nil
            }
            return event
        default:
            return event
        }
    }
}

// MARK: - Petite bulle d'information

@MainActor
final class Toast {
    static let shared = Toast()
    private var panel: NSPanel?
    private var work: DispatchWorkItem?

    func show(_ text: String) {
        guard let screen = NSScreen.main else { return }
        let dark = Theme.isDark()
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = dark ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.08, alpha: 1)
        let size = NSSize(width: label.fittingSize.width + 36, height: 38)
        let p = panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .floating
        p.ignoresMouseEvents = true
        let bg = NSView(frame: NSRect(origin: .zero, size: size))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = (dark ? NSColor(srgbRed: 0.06, green: 0.06, blue: 0.08, alpha: 0.97)
                                          : NSColor(white: 1, alpha: 0.98)).cgColor
        bg.layer?.cornerRadius = 19
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = Theme.accent.withAlphaComponent(0.6).cgColor
        label.frame = NSRect(x: 18, y: (38 - label.fittingSize.height) / 2, width: label.fittingSize.width,
                             height: label.fittingSize.height)
        bg.addSubview(label)
        p.contentView = bg
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.minY + 80, width: size.width, height: size.height),
                   display: true)
        p.orderFrontRegardless()
        panel = p
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel?.orderOut(nil) } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: w)
    }
}
