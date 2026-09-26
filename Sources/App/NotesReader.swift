import Foundation
import OSAKit
import SQLite3

/// Reads the notes in one Notes folder. Prefers the Notes database, which keeps
/// checklist ticks and list/heading styles (needs Full Disk Access); falls back
/// to Notes scripting, which only gives plain text.
enum NotesReader {
    enum Source: String {
        case database = "Notes database"
        case scripting = "Notes scripting"
    }

    static func read(folder: String, limit: Int) -> (notes: [BoardNote], source: Source, error: String?) {
        do {
            if let notes = try NotesDatabase.read(folder: folder, limit: limit) {
                return (notes, .database, nil)
            }
        } catch {
            log("database read failed: \(error)")
        }
        do {
            return (try NotesScript.read(folder: folder, limit: limit), .scripting, nil)
        } catch {
            return ([], .scripting, "\(error)")
        }
    }

    /// Notes' plain text, tidied: no repeated title, no runs of blank lines.
    static func tidy(_ lines: [NoteLine], title: String) -> [NoteLine] {
        var out = lines
        if let first = out.first, first.text.trimmingCharacters(in: .whitespaces) == title.trimmingCharacters(in: .whitespaces) {
            out.removeFirst()
        }
        out = out.enumerated().filter { i, line in !(line.text.isEmpty && (i == 0 || out[i - 1].text.isEmpty)) }.map(\.1)
        while out.last?.text.isEmpty == true { out.removeLast() }
        while out.first?.text.isEmpty == true { out.removeFirst() }
        return Array(out.prefix(60))
    }
}

struct ReadError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Notes database

enum NotesDatabase {
    static var url: URL {
        URL(fileURLWithPath: realHome).appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    }

    static var isReadable: Bool {
        guard let db = open() else { return false }
        sqlite3_close(db)
        return true
    }

    private static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let uri = "file:\(url.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? url.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT 1 FROM ZICCLOUDSYNCINGOBJECT LIMIT 1", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        return db
    }

    /// nil when the database isn't readable (no Full Disk Access) or the folder
    /// doesn't exist yet, so the caller falls back to scripting.
    static func read(folder: String, limit: Int) throws -> [BoardNote]? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT n.ZTITLE1, n.ZMODIFICATIONDATE1, d.ZDATA
        FROM ZICCLOUDSYNCINGOBJECT n
        JOIN ZICNOTEDATA d ON d.ZNOTE = n.Z_PK
        WHERE n.ZFOLDER IN (SELECT Z_PK FROM ZICCLOUDSYNCINGOBJECT
                            WHERE ZTITLE2 = ? AND IFNULL(ZMARKEDFORDELETION, 0) = 0)
          AND IFNULL(n.ZMARKEDFORDELETION, 0) = 0
          AND n.ZTITLE1 IS NOT NULL
        ORDER BY n.ZMODIFICATIONDATE1 DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw ReadError("query failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, folder, -1, transient)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var notes: [BoardNote] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let title = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let modified = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
            var lines: [NoteLine] = [NoteLine(text: "🔒 Locked or unreadable note")]
            if let blob = sqlite3_column_blob(stmt, 2) {
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 2)))
                if let parsed = NoteBody.lines(fromGzipped: data) { lines = parsed }
            }
            notes.append(BoardNote(title: title, lines: NotesReader.tidy(lines, title: title), modified: modified))
        }
        // An empty result may just mean the folder doesn't exist yet; scripting creates it.
        return notes.isEmpty ? nil : notes
    }
}

/// Decodes the gzipped protobuf Notes stores for each note body.
enum NoteBody {
    static func lines(fromGzipped data: Data) -> [NoteLine]? {
        guard let raw = gunzip(data) else { return nil }
        let root = Proto.fields([UInt8](raw))
        guard let doc = root.bytes(2), let note = Proto.fields(doc).bytes(3) else { return nil }
        let fields = Proto.fields(note)
        guard let textBytes = fields.bytes(2) else { return nil }
        let text = String(decoding: textBytes, as: UTF8.self) as NSString

        // Attribute runs cover the text in order; lengths are UTF-16 units.
        struct Style { var type = -1, indent = 0, done = false }
        var runs: [(end: Int, style: Style)] = []
        var pos = 0
        for run in fields.allBytes(5) {
            let r = Proto.fields(run)
            pos += Int(truncatingIfNeeded: r.varint(1) ?? 0)
            var style = Style()
            if let ps = r.bytes(2) {
                let p = Proto.fields(ps)
                style.type = p.varint(1).map { Int(truncatingIfNeeded: $0) } ?? -1
                style.indent = min(8, max(0, Int(truncatingIfNeeded: p.varint(4) ?? 0)))
                if let check = p.bytes(5) { style.done = (Proto.fields(check).varint(2) ?? 0) != 0 }
            }
            runs.append((pos, style))
        }
        func style(at offset: Int) -> Style {
            runs.first { offset < $0.end }?.style ?? Style()
        }

        var lines: [NoteLine] = []
        var start = 0
        let full = text.length
        while start <= full {
            let range = text.range(of: "\n", range: NSRange(location: start, length: full - start))
            let end = range.location == NSNotFound ? full : range.location
            let paragraph = text.substring(with: NSRange(location: start, length: end - start))
                .replacingOccurrences(of: "\u{FFFC}", with: "")
                .trimmingCharacters(in: .whitespaces)
            let s = style(at: start)
            let kind: NoteLine.Kind = switch s.type {
            case 0, 1, 2: .heading
            case 100, 101: .bullet
            case 102: .numbered
            case 103: .check
            default: .text
            }
            // The title paragraph (style 0) is shown as the card heading already.
            if !(s.type == 0 && lines.isEmpty) {
                lines.append(NoteLine(text: paragraph, kind: kind, done: kind == .check && s.done, indent: s.indent))
            }
            if range.location == NSNotFound { break }
            start = end + 1
        }
        return lines
    }

    /// gzip = 10+ byte header, raw DEFLATE body, 8 byte trailer.
    private static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 4 != 0 { guard i + 1 < b.count else { return nil }; i += 2 + Int(b[i]) + Int(b[i + 1]) << 8 }
        if flags & 8 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 16 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        return try? (Data(b[i..<(b.count - 8)]) as NSData).decompressed(using: .zlib) as Data
    }
}

/// Just enough protobuf to walk Notes' note format.
enum Proto {
    enum Value {
        case varint(UInt64)
        case bytes([UInt8])
    }

    static func fields(_ b: [UInt8]) -> [(Int, Value)] {
        var out: [(Int, Value)] = []
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < b.count {
                let byte = b[i]
                i += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < b.count, let key = varint() {
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let v = varint() else { return out }
                out.append((field, .varint(v)))
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return out }
                out.append((field, .bytes(Array(b[i..<(i + Int(len))]))))
                i += Int(len)
            case 1: i += 8
            case 5: i += 4
            default: return out
            }
        }
        return out
    }
}

extension Array where Element == (Int, Proto.Value) {
    func bytes(_ field: Int) -> [UInt8]? {
        for (f, v) in self where f == field { if case .bytes(let b) = v { return b } }
        return nil
    }

    func allBytes(_ field: Int) -> [[UInt8]] {
        compactMap { f, v in
            if f == field, case .bytes(let b) = v { return b }
            return nil
        }
    }

    func varint(_ field: Int) -> UInt64? {
        for (f, v) in self where f == field { if case .varint(let x) = v { return x } }
        return nil
    }
}

// MARK: - Notes scripting (fallback)

enum NotesScript {
    static func read(folder: String, limit: Int) throws -> [BoardNote] {
        let name = folder.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        const Notes = Application("Notes");
        let folders = Notes.folders.whose({name: "\(name)"})();
        if (folders.length === 0) {
          Notes.folders.push(Notes.Folder({name: "\(name)"}));
          folders = Notes.folders.whose({name: "\(name)"})();
        }
        const out = [];
        for (const f of folders) {
          for (const n of f.notes()) {
            out.push({title: n.name(), text: n.plaintext(), modified: n.modificationDate().toISOString()});
          }
        }
        JSON.stringify(out);
        """
        guard let language = OSALanguage(forName: "JavaScript") else { throw ReadError("JavaScript OSA unavailable") }
        var error: NSDictionary?
        let result = OSAScript(source: script, language: language).executeAndReturnError(&error)
        guard let json = result?.stringValue, let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else {
            throw ReadError(error?[OSAScriptErrorMessageKey] as? String ?? "Notes script failed")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return raw.map { n in
            let title = n["title"] ?? ""
            let lines = (n["text"] ?? "").components(separatedBy: .newlines)
                .map { NoteLine(text: $0.trimmingCharacters(in: .whitespaces)) }
            return BoardNote(title: title, lines: NotesReader.tidy(lines, title: title),
                             modified: n["modified"].flatMap(iso.date(from:)) ?? Date())
        }
        .sorted { $0.modified > $1.modified }
        .prefix(limit)
        .map { $0 }
    }
}

// MARK: - Helpers

let realHome = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("\(stamp) \(message)")
    fflush(stdout)
}
