import Foundation

/// Everything the screensaver shows. Written by Helm Sync, read by the saver.
struct Board: Codable {
    var updated: Date
    var notes: [BoardNote] = []
    var todo: [BoardTask] = []
    var done: [BoardTask] = []
    var notesError: String?
    var remindersError: String?

    /// Inside the screensaver's sandbox container, which Helm Sync can write to
    /// and the sandboxed saver can read. The real home directory is used so the
    /// path is the same from inside and outside the sandbox.
    static var fileURL: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Helm/board.json")
    }

    static func load() -> Board? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Board.self, from: data)
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

struct BoardNote: Codable {
    var title: String
    var lines: [String]
    var modified: Date
}

struct BoardTask: Codable {
    var title: String
    var list: String
    var due: Date?
    var completed: Date?
}
