import Foundation

/// Une recherche en français courant, traduite en filtres :
/// « le pdf que j'ai téléchargé depuis Gmail hier » → téléchargements, PDF, Gmail, hier.
struct ParsedQuery: Equatable {
    struct Anchor: Equatable {
        enum Relation: String { case before, after, during }
        var relation: Relation
        var name: String
    }
    struct Chip: Equatable, Hashable {
        var symbol: String
        var text: String
    }

    var terms: [String] = []
    var from: Date?
    var to: Date?
    var timeLabel: String?
    var kinds: Set<EventKind> = []
    var families: Set<FileFamily> = []
    var extensions: Set<String> = []
    var links = false
    var place: String?        // service ou appli (Gmail, WhatsApp, Safari, Figma…)
    var anchor: Anchor?

    var isEmpty: Bool {
        terms.isEmpty && from == nil && to == nil && kinds.isEmpty && families.isEmpty && extensions.isEmpty
            && !links && place == nil && anchor == nil
    }

    var chips: [Chip] {
        var c: [Chip] = []
        if let timeLabel { c.append(Chip(symbol: "calendar", text: timeLabel)) }
        for k in EventKind.allCases where kinds.contains(k) { c.append(Chip(symbol: k.symbol, text: k.verb)) }
        for f in FileFamily.allCases where families.contains(f) { c.append(Chip(symbol: "doc", text: f.label)) }
        for e in extensions.sorted() { c.append(Chip(symbol: "doc", text: "." + e)) }
        if links { c.append(Chip(symbol: "link", text: "Liens")) }
        if let place { c.append(Chip(symbol: "mappin.circle", text: place)) }
        if let anchor {
            let word = anchor.relation == .before ? "Avant" : anchor.relation == .after ? "Après" : "Pendant"
            c.append(Chip(symbol: "clock.arrow.circlepath", text: "\(word) \(anchor.name)"))
        }
        for t in terms { c.append(Chip(symbol: "textformat", text: "« \(t) »")) }
        return c
    }
}

struct QueryParser {
    var now: Date = Date()
    /// Noms d'applis connus (déjà vus par AikoMemo), pour comprendre « dans Figma », « avant d'ouvrir Premiere »…
    var knownApps: [String] = []

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "fr_FR")
        c.firstWeekday = 2
        c.timeZone = .current
        return c
    }

    static let services = [
        "gmail", "google drive", "drive", "wetransfer", "swisstransfer", "smash", "dropbox", "whatsapp", "discord",
        "slack", "notion", "canva", "frame.io", "vimeo", "youtube", "instagram", "facebook", "messenger", "telegram",
        "outlook", "onedrive", "sharepoint", "icloud", "airdrop", "safari", "chrome", "firefox", "arc", "brave",
        "messages", "imessage", "mail", "teams", "zoom", "github", "chatgpt", "claude", "amazon", "leboncoin",
        "vinted", "doctolib", "impots", "ameli", "caf", "la poste", "orange", "free", "sfr", "bouygues", "figma",
        "unsplash", "pexels", "freepik", "envato", "artlist", "pinterest", "linkedin",
    ]
    static let displayNames: [String: String] = [
        "gmail": "Gmail", "google drive": "Google Drive", "drive": "Google Drive", "wetransfer": "WeTransfer",
        "swisstransfer": "SwissTransfer", "whatsapp": "WhatsApp", "airdrop": "AirDrop", "imessage": "Messages",
        "icloud": "iCloud", "onedrive": "OneDrive", "sharepoint": "SharePoint", "youtube": "YouTube",
        "chatgpt": "ChatGPT", "github": "GitHub", "linkedin": "LinkedIn", "impots": "Impôts", "la poste": "La Poste",
        "frame.io": "Frame.io",
    ]

    /// Noms qui sont aussi des mots courants : il faut « depuis / sur / dans … » devant.
    static let ambiguous: Set<String> = ["mail", "free", "orange", "arc", "drive", "messages", "caf", "teams",
                                         "zoom", "smash", "brave", "claude", "figma", "canva", "notion"]

    private static let months = ["janvier", "fevrier", "mars", "avril", "mai", "juin", "juillet", "aout",
                                 "septembre", "octobre", "novembre", "decembre"]
    private static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]  // 1…7
    private static let numbers: [String: Int] = [
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6, "sept": 7, "huit": 8,
        "neuf": 9, "dix": 10, "quinze": 15, "vingt": 20, "trente": 30, "quelques": 3,
    ]

    private static let kindWords: [(EventKind, [String])] = [
        (.download, ["telecharge", "telecharges", "telechargee", "telechargees", "telechargement", "telechargements",
                     "download", "downloaded"]),
        (.clipboard, ["copie", "copiee", "copies", "copiees", "presse-papier", "presse-papiers", "colle", "collee",
                      "copied", "clipboard"]),
        (.opened, ["ouvert", "ouverte", "ouverts", "ouvertes", "consulte", "consultee", "regarde", "regardee",
                   "lu", "lue", "opened"]),
        (.created, ["cree", "creee", "crees", "creees", "enregistre", "enregistree", "enregistres", "sauvegarde",
                    "sauvegardee", "exporte", "exportee", "exportes", "created", "saved", "exported"]),
        (.modified, ["modifie", "modifiee", "modifies", "edite", "editee", "retouche", "retouchee", "modified",
                     "edited"]),
        (.app, ["appli", "applis", "application", "applications", "app", "apps", "logiciel", "logiciels"]),
    ]
    private static let familyWords: [(FileFamily, [String])] = [
        (.pdf, ["pdf", "pdfs"]),
        (.image, ["image", "images", "photo", "photos", "capture", "captures", "screenshot", "screenshots", "img",
                  "picture", "pictures"]),
        (.video, ["video", "videos", "rush", "rushs", "rushes", "film", "films", "clip", "clips", "sequence"]),
        (.audio, ["audio", "audios", "musique", "musiques", "morceau", "vocal", "vocaux", "voix",
                  "podcast"]),
        (.document, ["doc", "docs", "document", "documents", "texte", "textes", "word", "pages"]),
        (.spreadsheet, ["tableur", "tableurs", "excel", "tableau", "tableaux", "numbers", "csv"]),
        (.presentation, ["presentation", "presentations", "keynote", "powerpoint", "diapo", "diapos", "slides"]),
        (.archive, ["zip", "zips", "archive", "archives", "rar"]),
        (.code, ["code", "script", "scripts"]),
        (.design, ["psd", "maquette", "maquettes", "photoshop", "illustrator"]),
        (.project, ["drp", "davinci", "resolve", "timeline", "timelines"]),
    ]
    private static let linkWords = ["lien", "liens", "url", "urls", "link", "links"]
    private static let stopwords: Set<String> = [
        "le", "la", "les", "l", "un", "une", "des", "de", "du", "d", "au", "aux", "a", "et", "ou", "que", "qu",
        "qui", "quoi", "ce", "cet", "cette", "ces", "c", "ca", "cela", "j", "je", "ai", "avais", "avait", "etait",
        "etais", "suis", "est", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre",
        "leur", "leurs", "y", "en", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "m", "moi", "te",
        "t", "se", "s", "pour", "par", "avec", "sans", "sur", "sous", "dans", "vers", "chez", "fichier",
        "fichiers", "truc", "trucs", "chose", "choses", "machin", "quel", "quelle", "quels", "quelles",
        "retrouve", "retrouver", "trouve", "trouver", "cherche", "chercher", "montre", "montrer", "affiche",
        "donne", "voir", "veux", "voudrais", "besoin", "pas", "plus", "tres", "bien", "tout", "tous", "toute",
        "toutes", "deja", "encore", "juste", "quand", "comment", "depuis", "via", "the", "of", "from", "my",
        "dernier", "derniere", "derniers", "dernieres", "fois", "moment", "envoye", "envoyee", "envoyes",
        "ou", "c'est", "lequel", "laquelle", "celui", "celle", "fait", "faite", "faits", "eu", "avoir", "ete",
        "apres", "avant", "pendant",
    ]

    init(now: Date = Date(), knownApps: [String] = []) {
        self.now = now
        self.knownApps = knownApps
    }

    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "’", with: "'")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "fr_FR"))
            .lowercased()
    }

    func parse(_ raw: String) -> ParsedQuery {
        var q = ParsedQuery()
        var s = " " + Self.fold(raw) + " "

        func take(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) else {
                return nil
            }
            let ns = s as NSString
            var groups: [String] = []
            for i in 0..<m.numberOfRanges {
                let r = m.range(at: i)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            s = ns.replacingCharacters(in: m.range, with: " ")
            return groups
        }

        // Ancrage : « avant d'ouvrir Figma », « après Premiere », « pendant que j'étais sur Zoom »
        let apps = knownApps.map(Self.fold).filter { $0.count >= 2 }
        let names = Array(Set(apps + Self.services)).sorted { $0.count > $1.count }
        let any = names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        if !any.isEmpty {
            let verbs = #"(?:d'|de )?(?:avoir )?(?:ouvrir|ouvert|lancer|lance|utiliser|utilise|aller sur|etre sur|"#
                + #"passer sur|ferme|fermer|quitter|quitte)?\s*(?:sur |dans )?"#
            if let g = take(#"\b(avant|apres|pendant que j'etais sur|pendant que j'etais dans|pendant)\s+"# + verbs
                            + "(" + any + #")\b"#) {
                let rel: ParsedQuery.Anchor.Relation = g[1].hasPrefix("avant") ? .before
                    : g[1].hasPrefix("apres") ? .after : .during
                q.anchor = .init(relation: rel, name: display(g[2]))
            }
        }
        // Lieu : « depuis Gmail », « sur WhatsApp », « dans Safari », ou un service cité seul (« le pdf gmail »)
        let services = Self.services.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let appAlt = apps.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        let unambiguous = Self.services.filter { !Self.ambiguous.contains($0) }.sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        if let g = take(#"(?:\b(?:depuis|de|du|sur|via|par|dans|avec)\s+|\bd')("# + services + #")\b"#) {
            q.place = display(g[1])
        } else if !appAlt.isEmpty, let g = take(#"\b(?:depuis|sur|via|dans|avec)\s+("# + appAlt + #")\b"#) {
            q.place = display(g[1])
        } else if let g = take(#"\b("# + unambiguous + #")\b"#) {
            q.place = display(g[1])
        }
        if take(#"\bprojets? (?:davinci|resolve|premiere|final cut|fcp|after effects)\b"#) != nil {
            q.families.insert(.project)
        }
        // « reçu » : téléchargement seulement dans « j'ai reçu » (sinon c'est un reçu, un ticket)
        if take(#"\b(?:ai|as|a|avais|avait|avons|avez|ont|on m'a)\s+recu(?:e|s|es)?\b"#) != nil {
            q.kinds.insert(.download)
        }

        // Moment
        parseTime(&q, take)

        // Mots-clés de type d'action, de fichier, de lien
        var words = s.components(separatedBy: CharacterSet(charactersIn: " ,;:!?.()[]{}\"«»/\\").union(.whitespaces))
            .flatMap { $0.components(separatedBy: "'") }
            .filter { !$0.isEmpty }
        var rest: [String] = []
        let allExt = Set(FileFamily.allCases.flatMap(\.extensions))
        for w in words {
            if let k = Self.kindWords.first(where: { $0.1.contains(w) })?.0 { q.kinds.insert(k); continue }
            if let f = Self.familyWords.first(where: { $0.1.contains(w) })?.0 { q.families.insert(f); continue }
            if Self.linkWords.contains(w) { q.links = true; continue }
            if allExt.contains(w) { q.extensions.insert(w); continue }
            if w.hasPrefix("."), allExt.contains(String(w.dropFirst())) { q.extensions.insert(String(w.dropFirst())); continue }
            rest.append(w)
        }
        if q.links && q.kinds.isEmpty { q.kinds.insert(.clipboard) }
        words = rest.filter { !Self.stopwords.contains($0) && ($0.count >= 2 || $0.allSatisfy(\.isNumber)) }
        q.terms = words
        return q
    }

    private func display(_ folded: String) -> String {
        if let d = Self.displayNames[folded] { return d }
        if let app = knownApps.first(where: { Self.fold($0) == folded }) { return app }
        return folded.prefix(1).uppercased() + folded.dropFirst()
    }

    // MARK: - Dates

    private func startOfDay(_ d: Date) -> Date { cal.startOfDay(for: d) }
    private func day(_ offset: Int) -> Date { cal.date(byAdding: .day, value: offset, to: startOfDay(now))! }

    private func setDay(_ q: inout ParsedQuery, _ start: Date, label: String, part: String? = nil) {
        var from = start
        var to = cal.date(byAdding: .day, value: 1, to: start)!
        var label = label
        switch part.map(Self.fold) {
        case "matin"?: from = hour(start, 5); to = hour(start, 12); label += " matin"
        case "midi"?: from = hour(start, 11); to = hour(start, 14); label += " midi"
        case "apres-midi"?, "apres midi"?: from = hour(start, 12); to = hour(start, 18); label += " après-midi"
        case "soir"?: from = hour(start, 18); to = cal.date(byAdding: .day, value: 1, to: start)!; label += " soir"
        case "nuit"?: from = hour(start, 21); to = hour(cal.date(byAdding: .day, value: 1, to: start)!, 5)
            label += " nuit"
        default: break
        }
        q.from = from
        q.to = to
        q.timeLabel = label
    }

    private func hour(_ d: Date, _ h: Int) -> Date { cal.date(bySettingHour: h, minute: 0, second: 0, of: d)! }

    private func parseTime(_ q: inout ParsedQuery, _ take: (String) -> [String]?) {
        let at = take(#"(?<!il y )\b(?:vers|a)\s+(\d{1,2})\s?h(?:eures?)?\s?(\d{2})?\b"#)
        parseDay(&q, take)
        guard let at, let h = Int(at[1]), h < 24 else { return }
        let m = min(Int(at[2]) ?? 0, 59)
        let base = q.from.map { startOfDay($0) } ?? startOfDay(now)
        guard let t = cal.date(bySettingHour: h, minute: m, second: 0, of: base) else { return }
        q.from = t.addingTimeInterval(-3600)
        q.to = t.addingTimeInterval(3600)
        q.timeLabel = (q.timeLabel.map { $0 + ", " } ?? "") + "vers \(h)h" + (at[2].isEmpty ? "" : at[2])
    }

    private func parseDay(_ q: inout ParsedQuery, _ take: (String) -> [String]?) {
        let part = #"(?:\s+(matin|midi|apres[- ]midi|soir|nuit))?"#
        let wd = Self.weekdays.joined(separator: "|")
        let mo = Self.months.joined(separator: "|")
        let num = #"(\d+|"# + Self.numbers.keys.joined(separator: "|") + ")"

        if let g = take(#"\bil y a\s+"# + num + #"\s+(minutes?|min|heures?|h|jours?|semaines?|mois|ans?)\b"#) {
            let n = Int(g[1]) ?? Self.numbers[g[1]] ?? 1
            let unit = g[2]
            if unit.hasPrefix("min") || unit.hasPrefix("h") {
                let secs = Double(n) * (unit.hasPrefix("min") ? 60 : 3600)
                q.from = now.addingTimeInterval(-secs * 1.5 - 600)
                q.to = now.addingTimeInterval(-secs * 0.5 + 600)
                q.timeLabel = "Il y a \(n) \(unit.hasPrefix("min") ? "min" : "h")"
            } else if unit.hasPrefix("jour") {
                setDay(&q, day(-n), label: "Il y a \(n) jour\(n > 1 ? "s" : "")")
                q.from = cal.date(byAdding: .day, value: -1, to: q.from!)  // on élargit d'un jour de chaque côté
                q.to = cal.date(byAdding: .day, value: 1, to: q.to!)
            } else if unit.hasPrefix("semaine") {
                q.from = day(-7 * n - 4)
                q.to = day(-7 * n + 4)
                q.timeLabel = "Il y a \(n) semaine\(n > 1 ? "s" : "")"
            } else if unit == "mois" {
                q.from = cal.date(byAdding: .day, value: -30 * n - 12, to: startOfDay(now))
                q.to = cal.date(byAdding: .day, value: -30 * n + 12, to: startOfDay(now))
                q.timeLabel = "Il y a \(n) mois"
            } else {
                q.from = cal.date(byAdding: .month, value: -12 * n - 3, to: startOfDay(now))
                q.to = cal.date(byAdding: .month, value: -12 * n + 3, to: startOfDay(now))
                q.timeLabel = "Il y a \(n) an\(n > 1 ? "s" : "")"
            }
            return
        }
        if let g = take(#"\bdepuis\s+(hier|avant[- ]hier|ce matin|"# + wd + #")\b"#) {
            let start: Date
            switch g[1] {
            case "hier": start = day(-1)
            case "avant-hier", "avant hier": start = day(-2)
            case "ce matin": start = hour(day(0), 5)
            default: start = lastWeekday(g[1], allowToday: false)
            }
            q.from = start
            q.to = now.addingTimeInterval(60)
            q.timeLabel = "Depuis \(g[1])"
            return
        }
        if let g = take(#"\bavant[- ]hier"# + part + #"\b"#) { setDay(&q, day(-2), label: "Avant-hier", part: g[1]); return }
        if let g = take(#"\bhier"# + part + #"\b"#) { setDay(&q, day(-1), label: "Hier", part: g[1]); return }
        if take(#"\b(?:aujourd'?hui|aujourd hui|ajd)\b"#) != nil { setDay(&q, day(0), label: "Aujourd'hui"); return }
        if let g = take(#"\b(?:ce|cet)\s+(matin|midi|apres[- ]midi|soir)\b"#) {
            setDay(&q, day(0), label: "Aujourd'hui", part: g[1]); return
        }
        if take(#"\b(?:la semaine (?:derniere|passee)|semaine (?:derniere|passee))\b"#) != nil {
            let thisMonday = startOfWeek(now)
            q.from = cal.date(byAdding: .day, value: -7, to: thisMonday)
            q.to = thisMonday
            q.timeLabel = "Semaine dernière"
            return
        }
        if take(#"\bcette semaine\b"#) != nil {
            q.from = startOfWeek(now)
            q.to = now.addingTimeInterval(60)
            q.timeLabel = "Cette semaine"
            return
        }
        if take(#"\b(?:le )?week-?end dernier\b|\bce week-?end\b"#) != nil {
            let monday = startOfWeek(now)
            let isWeekend = [1, 7].contains(cal.component(.weekday, from: now))
            let sat = cal.date(byAdding: .day, value: isWeekend ? 5 : -2, to: monday)!
            q.from = sat
            q.to = cal.date(byAdding: .day, value: 2, to: sat)
            q.timeLabel = "Week-end"
            return
        }
        if take(#"\b(?:le )?mois (?:dernier|passe)\b"#) != nil {
            let first = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            q.from = cal.date(byAdding: .month, value: -1, to: first)
            q.to = first
            q.timeLabel = "Mois dernier"
            return
        }
        if take(#"\bce mois(?:-ci)?\b"#) != nil {
            q.from = cal.date(from: cal.dateComponents([.year, .month], from: now))
            q.to = now.addingTimeInterval(60)
            q.timeLabel = "Ce mois-ci"
            return
        }
        if let g = take(#"\b("# + wd + #")(?:\s+(dernier|passe))?"# + part + #"\b"#) {
            let d = lastWeekday(g[1], allowToday: g[2].isEmpty)
            setDay(&q, d, label: g[1].prefix(1).uppercased() + g[1].dropFirst() + (g[2].isEmpty ? "" : " dernier"),
                   part: g[3].isEmpty ? nil : g[3])
            return
        }
        if let g = take(#"\b(?:le\s+)?(\d{1,2})(?:er)?\s+("# + mo + #")(?:\s+(\d{4}))?\b"#) {
            let m = Self.months.firstIndex(of: g[2])! + 1
            if let d = date(day: Int(g[1])!, month: m, year: Int(g[3])) {
                setDay(&q, d, label: "\(Int(g[1])!) \(g[2])")
            }
            return
        }
        if let g = take(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#) {
            var y = Int(g[3])
            if let yy = y, yy < 100 { y = 2000 + yy }
            if let d = date(day: Int(g[1])!, month: Int(g[2])!, year: y) {
                setDay(&q, d, label: "\(g[1])/\(g[2])")
            }
            return
        }
        if let g = take(#"\ben\s+("# + mo + #")(?:\s+(\d{4}))?\b"#) {
            let m = Self.months.firstIndex(of: g[1])! + 1
            var comps = cal.dateComponents([.year], from: now)
            comps.month = m
            comps.day = 1
            if let y = Int(g[2]) { comps.year = y } else if m > cal.component(.month, from: now) { comps.year! -= 1 }
            if let first = cal.date(from: comps) {
                q.from = first
                q.to = cal.date(byAdding: .month, value: 1, to: first)
                q.timeLabel = g[1].prefix(1).uppercased() + g[1].dropFirst()
            }
            return
        }
        if let g = take(#"\ble\s+(\d{1,2})(?:er)?\b"#) {
            if let d = date(day: Int(g[1])!, month: nil, year: nil) { setDay(&q, d, label: "Le \(g[1])") }
            return
        }
    }

    private func startOfWeek(_ d: Date) -> Date {
        cal.dateInterval(of: .weekOfYear, for: d)?.start ?? startOfDay(d)
    }

    /// Le dernier « mardi » passé (aujourd'hui compris si allowToday).
    private func lastWeekday(_ name: String, allowToday: Bool) -> Date {
        let target = (Self.weekdays.firstIndex(of: name) ?? 1) + 1
        var d = startOfDay(now)
        if !allowToday { d = cal.date(byAdding: .day, value: -1, to: d)! }
        for _ in 0..<8 {
            if cal.component(.weekday, from: d) == target { return d }
            d = cal.date(byAdding: .day, value: -1, to: d)!
        }
        return d
    }

    /// Date du jour donné ; sans année (ou mois), on prend la plus récente qui n'est pas dans le futur.
    private func date(day: Int, month: Int?, year: Int?) -> Date? {
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.day = day
        if let month { comps.month = month }
        if let year { comps.year = year }
        guard var d = cal.date(from: comps) else { return nil }
        if year == nil && d > now {
            d = cal.date(byAdding: month == nil ? .month : .year, value: -1, to: d) ?? d
        }
        return d
    }
}
