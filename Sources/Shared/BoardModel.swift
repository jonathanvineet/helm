import Foundation

/// Everything the screensaver shows, plus how to show it. Written by Helm.app,
/// read by the sandboxed saver.
struct Board: Codable {
    var updated: Date
    var settings = HelmSettings()
    var notes: [BoardNote] = []
    var todo: [BoardTask] = []
    var done: [BoardTask] = []
    var notesError: String?
    var remindersError: String?
    /// Pages Helm's browser extension is watching. Optional so a board.json
    /// written by an older Helm still decodes.
    var watches: [BoardWatch]?

    /// Inside the screensaver's sandbox container: Helm.app can write there and
    /// the sandboxed saver can read it. Built from the real home directory so
    /// the path is the same from inside and outside the sandbox.
    static var directory: URL {
        container.appendingPathComponent("Data/Library/Application Support/Helm")
    }

    /// macOS creates this container the first time a third-party screensaver
    /// is loaded. Creating it ourselves leaves it without its metadata, so on a
    /// fresh Mac nothing is written until Helm has been picked in System Settings.
    static var container: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver")
    }

    static var containerReady: Bool {
        FileManager.default.fileExists(atPath: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist").path)
    }

    static var fileURL: URL { directory.appendingPathComponent("board.json") }
    static var photosURL: URL { directory.appendingPathComponent("Photos") }

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
        guard Self.containerReady else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: Self.container.path]) }
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

struct BoardNote: Codable {
    var title: String
    var lines: [NoteLine]
    var modified: Date
}

/// One paragraph of a note, keeping the formatting that matters on screen.
struct NoteLine: Codable, Hashable {
    enum Kind: String, Codable {
        case text, heading, bullet, numbered, check
    }

    var text: String
    var kind: Kind = .text
    var done = false
    var indent = 0
}

/// A page the browser extension is watching (extension/watcher), as shown on the board.
struct BoardWatch: Codable {
    enum State: String, Codable {
        case attention, pending, watching, done
    }

    var name: String
    var text: String  // the watched text, or a status like "Still in review"
    var quoted = false  // `text` is the page's own words
    var state: State
    var since: Date?
    var checked: Date?

    init(name: String, text: String, quoted: Bool = false, state: State, since: Date? = nil, checked: Date? = nil) {
        (self.name, self.text, self.quoted, self.state, self.since, self.checked) = (name, text, quoted, state, since, checked)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        quoted = try c.decodeIfPresent(Bool.self, forKey: .quoted) ?? false
        state = (try? c.decode(State.self, forKey: .state)) ?? .watching
        since = try c.decodeIfPresent(Date.self, forKey: .since)
        checked = try c.decodeIfPresent(Date.self, forKey: .checked)
    }

    /// Where the extension's latest watches are kept for Helm.app to read.
    static var fileURL: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Helm/watches.json")
    }

    /// watches.json holds one list per browser profile (each has its own copy
    /// of the extension), so profiles don't overwrite each other.
    struct Store: Codable {
        struct Source: Codable {
            var updated: Date
            var watches: [BoardWatch]
        }
        var sources: [String: Source] = [:]

        static func read() -> Store {
            guard let data = try? Data(contentsOf: BoardWatch.fileURL) else { return Store() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(Store.self, from: data)) ?? Store()
        }

        func write() throws {
            let url = BoardWatch.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: url, options: .atomic)
        }
    }

    /// Every profile's watches. A profile that hasn't reported in two weeks
    /// (extension removed, profile deleted) is left out.
    static func load() -> [BoardWatch] {
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        return Store.read().sources.values
            .filter { $0.updated > cutoff }
            .sorted { $0.updated < $1.updated }
            .flatMap(\.watches)
    }
}

struct BoardTask: Codable {
    var title: String
    var list: String
    var due: Date?
    var completed: Date?
}

/// Everything adjustable from Helm's Customize window.
struct HelmSettings: Codable, Equatable {
    // Content
    var notesFolder = "Helm"
    var showNotes = true
    var maxNotes = 12
    var hideTickedItems = false
    var showReminders = true
    var showDoneToday = true
    var reminderLists: [String] = []  // empty = every list
    var showClock = true
    var use24Hour = false
    var showWatches = true

    // Appearance
    var accentHex = "#34C759"
    var fontDesign = "default"  // default, rounded, serif, monospaced
    var textScale = 1.0
    var panelOpacity = 0.25
    var glassBlur = 28.0
    var backgroundDim = 0.35
    var columns = 0  // 0 = automatic
    var notesOnLeft = true

    // Slideshow
    var showPhotos = true
    var photoFolder = ""  // empty = the folder picked for the system photo slideshow
    var photoDuration = 12.0
    var zoomAmount = 1.0

    // Sync
    var syncInterval = 10.0

    init() {}

    // Decode field by field so settings saved by an older Helm keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HelmSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        notesFolder = v(.notesFolder, d.notesFolder)
        showNotes = v(.showNotes, d.showNotes)
        maxNotes = v(.maxNotes, d.maxNotes)
        hideTickedItems = v(.hideTickedItems, d.hideTickedItems)
        showReminders = v(.showReminders, d.showReminders)
        showDoneToday = v(.showDoneToday, d.showDoneToday)
        reminderLists = v(.reminderLists, d.reminderLists)
        showClock = v(.showClock, d.showClock)
        use24Hour = v(.use24Hour, d.use24Hour)
        showWatches = v(.showWatches, d.showWatches)
        accentHex = v(.accentHex, d.accentHex)
        fontDesign = v(.fontDesign, d.fontDesign)
        textScale = v(.textScale, d.textScale)
        panelOpacity = v(.panelOpacity, d.panelOpacity)
        glassBlur = v(.glassBlur, d.glassBlur)
        backgroundDim = v(.backgroundDim, d.backgroundDim)
        columns = v(.columns, d.columns)
        notesOnLeft = v(.notesOnLeft, d.notesOnLeft)
        showPhotos = v(.showPhotos, d.showPhotos)
        photoFolder = v(.photoFolder, d.photoFolder)
        photoDuration = v(.photoDuration, d.photoDuration)
        zoomAmount = v(.zoomAmount, d.zoomAmount)
        syncInterval = v(.syncInterval, d.syncInterval)
    }
}
