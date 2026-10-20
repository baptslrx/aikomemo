import Foundation

// Tests du cœur d'AikoMemo : compréhension des recherches, base de données, origine des téléchargements.

var failures: [String] = []
let ci = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok {
        failures.append(what)
        if ci { print("::error title=Test::\(what)") }
    }
}

var cal = Calendar(identifier: .gregorian)
cal.timeZone = .current
func at(_ d: Int, _ h: Int, _ m: Int = 0, month: Int = 10) -> Date {
    cal.date(from: DateComponents(year: 2026, month: month, day: d, hour: h, minute: m))!
}
let now = at(20, 15)  // mardi 20 octobre 2026, 15 h
let fmt = DateFormatter()
fmt.dateFormat = "EEE d/MM HH:mm"
fmt.locale = Locale(identifier: "fr_FR")
func show(_ q: ParsedQuery) -> String {
    var parts: [String] = []
    if let f = q.from, let t = q.to { parts.append("\(fmt.string(from: f)) → \(fmt.string(from: t))") }
    parts += q.chips.map(\.text)
    return parts.joined(separator: " | ")
}

print("== Compréhension des recherches")
let parser = QueryParser(now: now, knownApps: ["Figma", "DaVinci Resolve", "Safari", "Photos", "Aperçu"])

var q = parser.parse("le pdf que j'ai téléchargé depuis Gmail hier")
print("   " + show(q))
check(q.families == [.pdf] && q.kinds == [.download] && q.place == "Gmail" && q.terms.isEmpty
      && q.from == at(19, 0) && q.to == at(20, 0), "pdf + téléchargé + Gmail + hier")

q = parser.parse("la facture reçue sur WhatsApp la semaine dernière")
print("   " + show(q))
check(q.place == "WhatsApp" && q.terms == ["facture", "recue"] && q.from == at(12, 0) && q.to == at(19, 0),
      "« facture reçue » (reçue sans « j'ai » reste un mot) + semaine dernière")

q = parser.parse("le fichier que j'ai reçu par airdrop ce matin")
print("   " + show(q))
check(q.kinds == [.download] && q.place == "AirDrop" && q.from == at(20, 5) && q.to == at(20, 12),
      "j'ai reçu → téléchargement, AirDrop, ce matin")

q = parser.parse("le lien que j'ai copié avant d'ouvrir Figma")
print("   " + show(q))
check(q.links && q.kinds == [.clipboard] && q.anchor == .init(relation: .before, name: "Figma") && q.place == nil,
      "lien copié avant d'ouvrir Figma")

q = parser.parse("rush mardi dernier")
print("   " + show(q))
check(q.families == [.video] && q.from == at(13, 0) && q.to == at(14, 0), "vidéo + mardi dernier (pas aujourd'hui)")

q = parser.parse("photo lundi soir")
print("   " + show(q))
check(q.families == [.image] && q.place == nil && q.from == at(19, 18) && q.to == at(20, 0),
      "« photo » = image, pas l'appli Photos ; lundi soir")

q = parser.parse("devis client il y a 3 jours")
print("   " + show(q))
check(q.terms == ["devis", "client"] && q.from == at(16, 0) && q.to == at(19, 0), "il y a 3 jours (± 1 jour)")

q = parser.parse("ce que j'ai copié il y a 2 heures")
print("   " + show(q))
check(q.kinds == [.clipboard] && q.from! < at(20, 13) && q.to! > at(20, 13), "il y a 2 heures (pas « à 2 h »)")

q = parser.parse("export davinci hier vers 14h")
print("   " + show(q))
check(q.from == at(19, 13) && q.to == at(19, 15) && q.families == [.project], "hier vers 14h + projet DaVinci")

q = parser.parse("le contrat du 12 octobre")
print("   " + show(q))
check(q.terms == ["contrat"] && q.from == at(12, 0) && q.to == at(13, 0), "le 12 octobre")

q = parser.parse("mockup.psd dans Figma")
print("   " + show(q))
check(q.place == "Figma" && q.terms.contains("mockup"), "« dans Figma » = lieu")

q = parser.parse("le mail de Paul")
print("   " + show(q))
check(q.place == nil && q.terms == ["mail", "paul"], "« mail » seul n'est pas l'appli Mail")

q = parser.parse("Facture.PDF")
print("   " + show(q))
check(q.terms == ["facture"] && (q.families == [.pdf] || q.extensions == ["pdf"]), "nom.extension")

q = parser.parse("")
check(q.isEmpty, "recherche vide = tout récent")

print("== Origine des téléchargements")
var d = SourceNamer.describe(whereFroms: ["https://mail-attachment.googleusercontent.com/attachment/u/0/?x=1",
                                          "https://mail.google.com/"], quarantineAgent: "Google Chrome")
check(d.source == "Gmail", "pièce jointe Gmail (\(d.source ?? "nil"))")
d = SourceNamer.describe(whereFroms: [], quarantineAgent: "sharingd")
check(d.source == "AirDrop", "AirDrop (\(d.source ?? "nil"))")
d = SourceNamer.describe(whereFroms: ["https://download.wetransfer.com/eu2/abc"], quarantineAgent: "Safari")
check(d.source == "WeTransfer", "WeTransfer (\(d.source ?? "nil"))")
d = SourceNamer.describe(whereFroms: ["https://exemple-studio.fr/fichiers/brief.pdf"], quarantineAgent: "Safari")
check(d.source == "exemple-studio.fr", "site inconnu → son adresse (\(d.source ?? "nil"))")

print("== Base de données")
let dbURL = FileManager.default.temporaryDirectory.appendingPathComponent("aikomemo-test-\(UUID().uuidString).sqlite")
let store = try! Store(url: dbURL)
check(store.hasFTS, "recherche plein texte (FTS5) disponible")
let events: [MemoEvent] = [
    MemoEvent(ts: at(19, 10), kind: .download, title: "Facture-Octobre.pdf", path: "/Users/b/Downloads/Facture-Octobre.pdf",
              app: "Google Chrome", source: "Gmail", detail: "https://mail.google.com/", ext: "pdf"),
    MemoEvent(ts: at(19, 11), kind: .download, title: "Brief_épreuve.pdf", path: "/Users/b/Downloads/Brief_épreuve.pdf",
              app: "Safari", source: "WeTransfer", ext: "pdf"),
    MemoEvent(ts: at(20, 9, 30), kind: .clipboard, title: "https://www.figma.com/file/abc/Logo", app: "Safari",
              source: "Safari", detail: "https://www.figma.com/file/abc/Logo"),
    MemoEvent(ts: at(20, 9, 50), kind: .app, title: "Figma", duration: 1800),
    MemoEvent(ts: at(20, 11), kind: .created, title: "Interview_NTO_v3.drp", path: "/Users/b/Documents/NTO/Interview_NTO_v3.drp",
              app: "DaVinci Resolve", ext: "drp"),
    MemoEvent(ts: at(20, 14), kind: .clipboard, title: "Rendez-vous chez le client à 16 h", app: "Messages",
              source: "Messages", detail: "Rendez-vous chez le client à 16 h"),
    MemoEvent(ts: at(1, 9, month: 8), kind: .opened, title: "Ancien.pdf", path: "/Users/b/Ancien.pdf", ext: "pdf"),
]
for e in events { store.insert(e) }
check(store.count() == events.count, "\(events.count) événements enregistrés")

func titles(_ s: String) -> [String] {
    let p = QueryParser(now: now, knownApps: store.appNames())
    return store.search(p.parse(s)).map(\.title)
}
var r = titles("le pdf que j'ai téléchargé depuis Gmail hier")
check(r == ["Facture-Octobre.pdf"], "pdf Gmail d'hier → \(r)")
r = titles("brief epreuve")
check(r == ["Brief_épreuve.pdf"], "accents ignorés : « brief epreuve » → \(r)")
r = titles("lien copié avant d'ouvrir Figma")
check(r == ["https://www.figma.com/file/abc/Logo"], "lien copié avant Figma → \(r)")
r = titles("rendez-vous")
check(r == ["Rendez-vous chez le client à 16 h"], "texte copié retrouvé → \(r)")
r = titles("interv")
check(r == ["Interview_NTO_v3.drp"], "début de mot suffit → \(r)")
r = titles("projet davinci aujourd'hui")
check(r == ["Interview_NTO_v3.drp"], "projet DaVinci d'aujourd'hui → \(r)")
r = titles("")
check(r.count == events.count - 1 && !r.contains("Figma"), "vue récente (sans les applis) → \(r.count)")
r = titles("facture brief")
check(Set(r) == ["Facture-Octobre.pdf", "Brief_épreuve.pdf"], "aucun résultat avec tous les mots → au moins un → \(r)")
let removed = store.purge(olderThan: at(1, 0))
check(store.count() == events.count - 1 && removed.isEmpty, "effacement automatique des anciens éléments")
store.deleteAll()
check(store.count() == 0 && titles("facture").isEmpty, "tout effacer")
try? FileManager.default.removeItem(at: dbURL)

if failures.isEmpty { print("\nTout est OK"); exit(0) }
print("\nÉCHECS :\n" + failures.joined(separator: "\n"))
exit(1)
