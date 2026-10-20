import Foundation

enum EventKind: String, CaseIterable, Codable {
    case download, created, modified, opened, clipboard, app

    var verb: String {
        switch self {
        case .download: return "Téléchargé"
        case .created: return "Créé"
        case .modified: return "Modifié"
        case .opened: return "Ouvert"
        case .clipboard: return "Copié"
        case .app: return "Utilisé"
        }
    }

    var symbol: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .created: return "plus.circle"
        case .modified: return "pencil.circle"
        case .opened: return "eye.circle"
        case .clipboard: return "doc.on.clipboard"
        case .app: return "app"
        }
    }
}

struct MemoEvent: Identifiable, Equatable {
    var id: Int64 = 0
    var ts: Date
    var kind: EventKind
    var title: String
    var path: String?
    var app: String?       // appli au premier plan à ce moment-là
    var source: String?    // Gmail, WhatsApp, AirDrop… (téléchargements) ou appli d'origine (copies)
    var detail: String?    // texte copié, adresse d'origine…
    var duration: Double = 0
    var ext: String?

    var folder: String? {
        guard let path else { return nil }
        return (path as NSString).deletingLastPathComponent
    }
}

/// Familles de fichiers reconnues dans les recherches (« le pdf », « la vidéo »…).
enum FileFamily: String, CaseIterable {
    case pdf, image, video, audio, document, spreadsheet, presentation, archive, code, design, project

    var label: String {
        switch self {
        case .pdf: return "PDF"
        case .image: return "Images"
        case .video: return "Vidéos"
        case .audio: return "Audio"
        case .document: return "Documents"
        case .spreadsheet: return "Tableurs"
        case .presentation: return "Présentations"
        case .archive: return "Archives"
        case .code: return "Code"
        case .design: return "Design"
        case .project: return "Projets vidéo"
        }
    }

    var extensions: [String] {
        switch self {
        case .pdf: return ["pdf"]
        case .image: return ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "raw",
                             "cr2", "cr3", "nef", "arw", "dng"]
        case .video: return ["mov", "mp4", "m4v", "mxf", "braw", "r3d", "avi", "mkv", "webm", "mts", "insv"]
        case .audio: return ["wav", "mp3", "aac", "m4a", "aif", "aiff", "flac", "ogg"]
        case .document: return ["doc", "docx", "pages", "txt", "rtf", "md", "odt"]
        case .spreadsheet: return ["xls", "xlsx", "numbers", "csv", "ods"]
        case .presentation: return ["key", "ppt", "pptx", "odp"]
        case .archive: return ["zip", "rar", "7z", "tar", "gz", "dmg"]
        case .code: return ["swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "php", "json", "sql", "sh"]
        case .design: return ["psd", "ai", "fig", "sketch", "xd", "afphoto", "afdesign", "indd", "eps", "prproj", "aep"]
        case .project: return ["drp", "drt", "fcpxml", "prproj", "aep", "xml", "edl", "otio"]
        }
    }
}

/// D'où vient un téléchargement : adresse d'origine (kMDItemWhereFroms) ou appli qui l'a reçu (quarantaine).
enum SourceNamer {
    private static let domains: [(String, String)] = [
        ("mail.google.", "Gmail"), ("gmail", "Gmail"), ("mail-attachment.googleusercontent", "Gmail"), ("googleusercontent.com", "Google Drive"),
        ("drive.google.", "Google Drive"), ("docs.google.", "Google Docs"), ("photos.google.", "Google Photos"),
        ("whatsapp", "WhatsApp"), ("wetransfer.com", "WeTransfer"), ("we.tl", "WeTransfer"),
        ("swisstransfer", "SwissTransfer"), ("smash", "Smash"), ("dropbox", "Dropbox"),
        ("discordapp", "Discord"), ("discord", "Discord"), ("slack", "Slack"), ("notion", "Notion"),
        ("figma", "Figma"), ("canva", "Canva"), ("frame.io", "Frame.io"), ("vimeo", "Vimeo"),
        ("youtube", "YouTube"), ("instagram", "Instagram"), ("fbcdn", "Facebook"), ("facebook", "Facebook"),
        ("messenger", "Messenger"), ("telegram", "Telegram"), ("outlook", "Outlook"), ("office", "Microsoft 365"),
        ("sharepoint", "SharePoint"), ("onedrive", "OneDrive"), ("live.com", "Outlook"), ("icloud", "iCloud"),
        ("apple.com", "Apple"), ("github", "GitHub"), ("teams", "Teams"), ("linkedin", "LinkedIn"),
        ("pinterest", "Pinterest"), ("unsplash", "Unsplash"), ("pexels", "Pexels"), ("freepik", "Freepik"),
        ("envato", "Envato"), ("artlist", "Artlist"), ("epidemicsound", "Epidemic Sound"),
        ("blackmagicdesign", "Blackmagic"), ("adobe", "Adobe"), ("laposte", "La Poste"), ("orange.fr", "Orange"),
        ("free.fr", "Free"), ("sfr", "SFR"), ("bouyguestelecom", "Bouygues"), ("impots.gouv", "Impôts"),
        ("ameli", "Ameli"), ("caf.fr", "CAF"), ("doctolib", "Doctolib"), ("amazon", "Amazon"),
        ("leboncoin", "Leboncoin"), ("vinted", "Vinted"), ("chatgpt", "ChatGPT"), ("openai", "ChatGPT"),
        ("claude.ai", "Claude"), ("anthropic", "Claude"),
    ]

    private static let agents: [String: String] = [
        "sharingd": "AirDrop", "AirDrop": "AirDrop", "Mail": "Mail", "Messages": "Messages",
        "WhatsApp": "WhatsApp", "Slack": "Slack", "Discord": "Discord", "Telegram": "Telegram",
        "Safari": "Safari", "Google Chrome": "Chrome", "Firefox": "Firefox", "Arc": "Arc", "Brave Browser": "Brave",
        "Microsoft Edge": "Edge", "Opera": "Opera", "Microsoft Outlook": "Outlook", "Spark": "Spark",
        "Microsoft Teams": "Teams", "zoom.us": "Zoom",
    ]

    static func name(forURL raw: String) -> String? {
        let host = URL(string: raw)?.host?.lowercased() ?? raw.lowercased()
        for (needle, name) in domains where host.contains(needle) { return name }
        if raw.lowercased().hasPrefix("http"), let h = URL(string: raw)?.host {
            return h.replacingOccurrences(of: "www.", with: "")
        }
        return nil
    }

    static func name(forAgent agent: String) -> String {
        agents[agent] ?? agent
    }

    /// Nom de service pour un fichier téléchargé, à partir de ses attributs étendus.
    static func describe(whereFroms: [String], quarantineAgent: String?) -> (source: String?, url: String?) {
        // Les messageries (Gmail…) passent souvent par une adresse de stockage : on regarde toutes les adresses
        let urls = whereFroms.filter { !$0.isEmpty }
        for u in urls.reversed() {   // la dernière est souvent la page d'origine (le site), la première le fichier
            if let n = name(forURL: u), !n.contains(".") { return (n, urls.first) }
        }
        if let agent = quarantineAgent, !agent.isEmpty {
            let n = name(forAgent: agent)
            if n == "AirDrop" { return (n, urls.first) }
            if let first = urls.first, let host = name(forURL: first) { return (host, first) }
            return (n, urls.first)
        }
        if let first = urls.first { return (name(forURL: first), first) }
        return (nil, nil)
    }
}
