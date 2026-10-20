import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// La mémoire elle-même : une base SQLite sur le Mac, avec recherche plein texte (FTS5).
final class Store {
    private var db: OpaquePointer?
    private(set) var hasFTS = false
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw StoreError.open(url.path) }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
            CREATE TABLE IF NOT EXISTS events(
              id INTEGER PRIMARY KEY, ts REAL NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL,
              path TEXT, app TEXT, source TEXT, detail TEXT, duration REAL DEFAULT 0, ext TEXT)
            """)
        exec("CREATE INDEX IF NOT EXISTS events_ts ON events(ts)")
        exec("CREATE INDEX IF NOT EXISTS events_path ON events(path)")
        hasFTS = exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
              title, path, app, source, detail, content='events', content_rowid='id',
              tokenize='unicode61 remove_diacritics 2')
            """)
        if hasFTS {
            exec("""
                CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
                  INSERT INTO events_fts(rowid, title, path, app, source, detail)
                  VALUES (new.id, new.title, new.path, new.app, new.source, new.detail); END
                """)
            exec("""
                CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
                  INSERT INTO events_fts(events_fts, rowid, title, path, app, source, detail)
                  VALUES ('delete', old.id, old.title, old.path, old.app, old.source, old.detail); END
                """)
            exec("""
                CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
                  INSERT INTO events_fts(events_fts, rowid, title, path, app, source, detail)
                  VALUES ('delete', old.id, old.title, old.path, old.app, old.source, old.detail);
                  INSERT INTO events_fts(rowid, title, path, app, source, detail)
                  VALUES (new.id, new.title, new.path, new.app, new.source, new.detail); END
                """)
        }
    }

    deinit { sqlite3_close(db) }

    enum StoreError: Error { case open(String) }

    // MARK: - Écriture

    @discardableResult
    func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        let ok = sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK
        if let err { NSLog("AikoMemo SQL : %@", String(cString: err)); sqlite3_free(err) }
        return ok
    }

    private enum Value { case text(String?), real(Double), int(Int64) }

    private func prepare(_ sql: String, _ args: [Value]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            NSLog("AikoMemo SQL : %@", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s?): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .text(nil): sqlite3_bind_null(stmt, idx)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            }
        }
        return stmt
    }

    @discardableResult
    private func run(_ sql: String, _ args: [Value] = []) -> Bool {
        guard let stmt = prepare(sql, args) else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    @discardableResult
    func insert(_ e: MemoEvent) -> Int64 {
        run("INSERT INTO events(ts, kind, title, path, app, source, detail, duration, ext) VALUES (?,?,?,?,?,?,?,?,?)",
            [.real(e.ts.timeIntervalSince1970), .text(e.kind.rawValue), .text(e.title), .text(e.path), .text(e.app),
             .text(e.source), .text(e.detail), .real(e.duration), .text(e.ext)])
        return sqlite3_last_insert_rowid(db)
    }

    func update(_ e: MemoEvent) {
        run("UPDATE events SET ts=?, kind=?, title=?, path=?, app=?, source=?, detail=?, duration=?, ext=? WHERE id=?",
            [.real(e.ts.timeIntervalSince1970), .text(e.kind.rawValue), .text(e.title), .text(e.path), .text(e.app),
             .text(e.source), .text(e.detail), .real(e.duration), .text(e.ext), .int(e.id)])
    }

    func setDuration(_ id: Int64, _ seconds: Double) {
        run("UPDATE events SET duration=? WHERE id=?", [.real(seconds), .int(id)])
    }

    func touch(_ id: Int64, at date: Date) {
        run("UPDATE events SET ts=? WHERE id=?", [.real(date.timeIntervalSince1970), .int(id)])
    }

    func delete(_ id: Int64) { run("DELETE FROM events WHERE id=?", [.int(id)]) }

    /// Supprime ce qui est plus ancien que la date ; renvoie les chemins des images de presse-papiers à effacer.
    @discardableResult
    func purge(olderThan date: Date) -> [String] {
        let old = select("SELECT * FROM events WHERE ts < ? AND kind='clipboard' AND detail LIKE 'image:%'",
                         [.real(date.timeIntervalSince1970)]).compactMap { $0.detail?.replacingOccurrences(of: "image:", with: "") }
        run("DELETE FROM events WHERE ts < ?", [.real(date.timeIntervalSince1970)])
        return old
    }

    func deleteAll() {
        run("DELETE FROM events")
        if hasFTS { exec("INSERT INTO events_fts(events_fts) VALUES('rebuild')") }
        exec("VACUUM")
    }

    // MARK: - Lecture

    private func row(_ stmt: OpaquePointer) -> MemoEvent {
        func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        return MemoEvent(id: sqlite3_column_int64(stmt, 0),
                         ts: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                         kind: EventKind(rawValue: text(2) ?? "") ?? .opened,
                         title: text(3) ?? "", path: text(4), app: text(5), source: text(6), detail: text(7),
                         duration: sqlite3_column_double(stmt, 8), ext: text(9))
    }

    private func select(_ sql: String, _ args: [Value]) -> [MemoEvent] {
        guard let stmt = prepare(sql, args) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [MemoEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(row(stmt)) }
        return out
    }

    func count() -> Int {
        guard let stmt = prepare("SELECT COUNT(*) FROM events", []) else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func latest(path: String, kinds: [EventKind], since: Date) -> MemoEvent? {
        let marks = kinds.map { _ in "?" }.joined(separator: ",")
        return select("SELECT * FROM events WHERE path=? AND ts>=? AND kind IN (\(marks)) ORDER BY ts DESC LIMIT 1",
                      [Value.text(path), Value.real(since.timeIntervalSince1970)] + kinds.map { Value.text($0.rawValue) }).first
    }

    func recent(limit: Int = 80) -> [MemoEvent] {
        select("SELECT * FROM events WHERE kind != 'app' ORDER BY ts DESC LIMIT ?", [.int(Int64(limit))])
    }

    /// Noms des applis déjà vues (pour comprendre « dans Figma »).
    func appNames() -> [String] {
        guard let stmt = prepare("SELECT DISTINCT title FROM events WHERE kind='app' LIMIT 400", []) else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// Périodes d'utilisation d'une appli (ou d'un service ouvert dans le navigateur).
    func sessions(named name: String, from: Date?, to: Date?) -> [(start: Date, end: Date)] {
        var sql = "SELECT * FROM events WHERE kind='app' AND title LIKE ?"
        var args: [Value] = [.text("%\(name)%")]
        if let from { sql += " AND ts >= ?"; args.append(.real(from.timeIntervalSince1970 - 3600)) }
        if let to { sql += " AND ts <= ?"; args.append(.real(to.timeIntervalSince1970)) }
        sql += " ORDER BY ts ASC LIMIT 2000"
        return select(sql, args).map { (start: $0.ts, end: $0.ts.addingTimeInterval(max($0.duration, 30))) }
    }

    // MARK: - Recherche

    func search(_ q: ParsedQuery, limit: Int = 200) -> [MemoEvent] {
        if q.isEmpty { return recent(limit: limit) }
        var sql = "SELECT * FROM events WHERE 1=1"
        var args: [Value] = []

        if let from = q.from { sql += " AND ts >= ?"; args.append(.real(from.timeIntervalSince1970)) }
        if let to = q.to { sql += " AND ts < ?"; args.append(.real(to.timeIntervalSince1970)) }
        if !q.kinds.isEmpty {
            var kinds = q.kinds
            if kinds.contains(.created) { kinds.insert(.download) }   // « enregistré » couvre aussi les téléchargements
            sql += " AND kind IN (\(kinds.map { _ in "?" }.joined(separator: ",")))"
            args += kinds.map { Value.text($0.rawValue) }
        } else {
            sql += " AND kind != 'app'"
        }
        let exts = q.extensions.union(q.families.flatMap(\.extensions))
        if !exts.isEmpty {
            sql += " AND ext IN (\(exts.map { _ in "?" }.joined(separator: ",")))"
            args += exts.map { Value.text($0) }
        }
        if q.links { sql += " AND (detail LIKE 'http%' OR title LIKE 'http%')" }
        if let place = q.place {
            sql += " AND (source LIKE ? OR app LIKE ? OR detail LIKE ?)"
            args += [.text("%\(place)%"), .text("%\(place)%"), .text("%\(place.lowercased())%")]
        }
        if let anchor = q.anchor {
            let windows = anchorWindows(anchor, from: q.from, to: q.to)
            if windows.isEmpty { return [] }
            sql += " AND (" + windows.map { _ in "(ts >= ? AND ts <= ?)" }.joined(separator: " OR ") + ")"
            for w in windows { args += [.real(w.0.timeIntervalSince1970), .real(w.1.timeIntervalSince1970)] }
        }

        let base = sql
        let baseArgs = args
        if !q.terms.isEmpty {
            if hasFTS {
                let match = q.terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }
                var found = select(base + " AND id IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?)"
                                   + " ORDER BY ts DESC LIMIT ?",
                                   baseArgs + [.text(match.joined(separator: " ")), .int(Int64(limit))])
                if found.isEmpty && match.count > 1 {
                    found = select(base + " AND id IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?)"
                                   + " ORDER BY ts DESC LIMIT ?",
                                   baseArgs + [.text(match.joined(separator: " OR ")), .int(Int64(limit))])
                }
                return found
            }
            for t in q.terms {
                sql += " AND (title LIKE ? OR path LIKE ? OR detail LIKE ? OR source LIKE ? OR app LIKE ?)"
                args += Array(repeating: Value.text("%\(t)%"), count: 5)
            }
        }
        sql += " ORDER BY ts DESC LIMIT ?"
        args.append(.int(Int64(limit)))
        return select(sql, args)
    }

    /// « avant d'ouvrir Figma » → les 30 minutes précédant chaque ouverture de Figma (sur la période demandée).
    func anchorWindows(_ a: ParsedQuery.Anchor, from: Date?, to: Date?) -> [(Date, Date)] {
        let from = from ?? Date().addingTimeInterval(-60 * 86400)
        let sessions = self.sessions(named: a.name, from: from, to: to)
        // Regroupe les allers-retours rapprochés : une « séance » commence après 15 min sans l'appli
        var merged: [(start: Date, end: Date)] = []
        for s in sessions {
            if let last = merged.last, s.start.timeIntervalSince(last.end) < 15 * 60 {
                merged[merged.count - 1].end = max(last.end, s.end)
            } else {
                merged.append(s)
            }
        }
        let window: TimeInterval = 30 * 60
        return merged.suffix(60).map { s -> (Date, Date) in
            switch a.relation {
            case .before: return (s.start.addingTimeInterval(-window), s.start.addingTimeInterval(60))
            case .after: return (s.end.addingTimeInterval(-60), s.end.addingTimeInterval(window))
            case .during: return (s.start, s.end)
            }
        }
    }
}
