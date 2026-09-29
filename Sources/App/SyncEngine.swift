import AppKit
import EventKit
import ImageIO
import UniformTypeIdentifiers

/// Keeps board.json (what the screensaver shows) up to date, and owns the
/// settings the Customize window edits.
@MainActor
final class SyncEngine: ObservableObject {
    @Published var settings: HelmSettings {
        didSet {
            guard settings != oldValue else { return }
            persist()
            if settings.syncInterval != oldValue.syncInterval { scheduleTimer() }
            if settings.photoFolder != oldValue.photoFolder { syncPhotos() }
            syncNow()
        }
    }

    @Published private(set) var board: Board?
    @Published private(set) var notesSource: NotesReader.Source?
    @Published private(set) var fullDiskAccess = NotesDatabase.isReadable
    @Published private(set) var remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
    @Published private(set) var reminderListNames: [String] = []
    @Published private(set) var photoCount = 0

    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "helm.sync", qos: .utility)
    private var timer: Timer?
    private var syncing = false
    private var pending = false

    init() {
        let saved = UserDefaults.standard.data(forKey: "settings").flatMap { try? JSONDecoder().decode(HelmSettings.self, from: $0) }
        settings = saved ?? HelmSettings()
    }

    func start() {
        store.requestFullAccessToReminders { _, _ in
            DispatchQueue.main.async { self.remindersAccess = EKEventStore.authorizationStatus(for: .reminder); self.syncNow() }
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { self.syncNow() }
        }
        scheduleTimer()
        syncNow()
        syncPhotos()
        let photoTimer = Timer(timeInterval: 300, repeats: true) { _ in MainActor.assumeIsolated { self.syncPhotos() } }
        RunLoop.main.add(photoTimer, forMode: .common)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "settings") }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: max(3, settings.syncInterval), repeats: true) { _ in
            MainActor.assumeIsolated { self.syncNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func syncNow() {
        if syncing { pending = true; return }
        syncing = true
        let settings = self.settings
        let store = self.store
        queue.async {
            let result = Self.gather(settings: settings, store: store)
            DispatchQueue.main.async {
                self.board = result.board
                self.notesSource = result.source
                self.fullDiskAccess = result.source == .database || NotesDatabase.isReadable
                self.reminderListNames = result.lists
                self.remindersAccess = EKEventStore.authorizationStatus(for: .reminder)
                self.syncing = false
                if self.pending {
                    self.pending = false
                    self.syncNow()
                }
            }
        }
    }

    // MARK: Gathering (off the main thread)

    private nonisolated static func gather(settings: HelmSettings, store: EKEventStore) -> (board: Board, source: NotesReader.Source, lists: [String]) {
        var board = Board(updated: Date(), settings: settings)
        let notes = NotesReader.read(folder: settings.notesFolder, limit: 24)
        board.notes = notes.notes
        board.notesError = notes.error

        let lists = store.calendars(for: .reminder).map(\.title).sorted()
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            store.reset()  // drop cached reminders so edits show up now
            let calendars = store.calendars(for: .reminder)
                .filter { settings.reminderLists.isEmpty || settings.reminderLists.contains($0.title) }
            if !calendars.isEmpty {
                let cal = Calendar.current
                let open = fetch(store, store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
                let doneToday = fetch(store, store.predicateForCompletedReminders(withCompletionDateStarting: cal.startOfDay(for: Date()),
                                                                                  ending: Date(), calendars: calendars))
                func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { cal.date(from: $0) } }
                board.todo = open
                    .sorted { (due($0) ?? .distantFuture, $0.creationDate ?? .distantPast) < (due($1) ?? .distantFuture, $1.creationDate ?? .distantPast) }
                    .prefix(20)
                    .map { BoardTask(title: $0.title ?? "", list: $0.calendar.title, due: due($0)) }
                board.done = doneToday
                    .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
                    .prefix(10)
                    .map { BoardTask(title: $0.title ?? "", list: $0.calendar.title, completed: $0.completionDate) }
            }
        } else {
            board.remindersError = "Allow Reminders access in Helm → Customize"
        }

        do {
            try board.save()
        } catch {
            log("write failed: \(error)")
        }
        return (board, notes.source, lists)
    }

    private nonisolated static func fetch(_ store: EKEventStore, _ predicate: NSPredicate) -> [EKReminder] {
        let done = DispatchSemaphore(value: 0)
        var found: [EKReminder] = []
        store.fetchReminders(matching: predicate) { reminders in
            found = reminders ?? []
            done.signal()
        }
        done.wait()
        return found
    }

    // MARK: Photos

    /// The folder the slideshow uses: the one chosen in Customize, else the one
    /// picked for the system photo slideshow, else ~/Downloads/wallpaper.
    var photoSource: URL {
        if !settings.photoFolder.isEmpty { return URL(fileURLWithPath: settings.photoFolder) }
        let byHost = URL(fileURLWithPath: realHome).appendingPathComponent("Library/Preferences/ByHost")
        let prefs = (try? FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil)) ?? []
        if let plist = prefs.first(where: { $0.lastPathComponent.hasPrefix("com.apple.ScreenSaverPhotoChooser.") }),
           let path = NSDictionary(contentsOf: plist)?["SelectedFolderPath"] as? String {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: realHome).appendingPathComponent("Downloads/wallpaper")
    }

    /// Copies (downsized) photos to where the sandboxed screensaver can read them.
    func syncPhotos() {
        let source = photoSource
        if photoCount == 0 { photoCount = PhotoSync.existing(in: Board.photosURL) }
        queue.async {
            let count = PhotoSync.run(from: source, to: Board.photosURL)
            DispatchQueue.main.async { self.photoCount = count }
        }
    }
}

enum PhotoSync {
    static func run(from source: URL, to dest: URL) -> Int {
        guard Board.containerReady else { return 0 }
        let fm = FileManager.default
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "webp"]
        // If the folder can't be read (no Downloads access yet, a drive not
        // mounted), keep the copies the screensaver already has.
        let listing: [URL]
        do {
            listing = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.contentModificationDateKey])
        } catch {
            NSLog("Helm: can't read photo folder %@: %@", source.path, error.localizedDescription)
            return existing(in: dest)
        }
        let photos = listing
            .filter { exts.contains($0.pathExtension.lowercased()) }
        var wanted = Set<String>()
        let maxPixels = Int((NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000) * 1.25)
        for photo in photos {
            let name = photo.deletingPathExtension().lastPathComponent + ".jpg"
            wanted.insert(name)
            let target = dest.appendingPathComponent(name)
            let srcDate = (try? photo.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let dstDate = (try? target.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let dstDate, dstDate >= srcDate { continue }
            guard let src = CGImageSourceCreateWithURL(photo as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                  ] as CFDictionary),
                  let out = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            CGImageDestinationFinalize(out)
        }
        for old in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] where !wanted.contains(old) {
            try? fm.removeItem(at: dest.appendingPathComponent(old))
        }
        return wanted.count
    }

    static func existing(in dest: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dest.path)) ?? []).filter { $0.hasSuffix(".jpg") }.count
    }
}
