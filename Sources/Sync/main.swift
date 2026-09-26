import EventKit
import Foundation
import OSAKit

// Helm Sync: gathers the Notes "Helm" folder and Reminders into board.json for
// the screensaver, every `interval` seconds. Stays running (launched at login by
// a LaunchAgent): macOS asks for "access data from other apps" per process, so a
// fresh process per sync would prompt every time.

let folderName = "Helm"
let interval: UInt32 = 10

// MARK: Notes (via JavaScript for Automation; Notes has no framework API)

let notesScript = """
const Notes = Application("Notes");
let folders = Notes.folders.whose({name: "\(folderName)"})();
if (folders.length === 0) {
  Notes.folders.push(Notes.Folder({name: "\(folderName)"}));
  folders = Notes.folders.whose({name: "\(folderName)"})();
  folders[0].notes.push(Notes.Note({body:
    "<h1>Welcome to Helm</h1><div>Notes in the Helm folder show on your screensaver.</div>" +
    "<div>The first line is the heading.</div><div>Everything else shows underneath.</div>"}));
}
const out = [];
for (const f of folders) {
  for (const n of f.notes()) {
    out.push({title: n.name(), text: n.plaintext(), modified: n.modificationDate().toISOString()});
  }
}
JSON.stringify(out);
"""

struct RawNote: Decodable {
    let title: String
    let text: String
    let modified: Date
}

func fetchNotes() throws -> [BoardNote] {
    guard let language = OSALanguage(forName: "JavaScript") else { throw SyncError("JavaScript OSA unavailable") }
    var error: NSDictionary?
    let result = OSAScript(source: notesScript, language: language).executeAndReturnError(&error)
    guard let json = result?.stringValue, let data = json.data(using: .utf8) else {
        throw SyncError(error?[OSAScriptErrorMessageKey] as? String ?? "Notes script failed")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { d in
        let s = try d.singleValueContainer().decode(String.self)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? Date()
    }
    return try decoder.decode([RawNote].self, from: data)
        .sorted { $0.modified > $1.modified }
        .prefix(24)
        .map { raw in
            var lines = raw.text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            if lines.first == raw.title.trimmingCharacters(in: .whitespaces) { lines.removeFirst() }
            // Collapse runs of blank lines and trim blank edges.
            lines = lines.enumerated().filter { i, line in !(line.isEmpty && (i == 0 || lines[i - 1].isEmpty)) }.map(\.1)
            while lines.last?.isEmpty == true { lines.removeLast() }
            while lines.first?.isEmpty == true { lines.removeFirst() }
            return BoardNote(title: raw.title, lines: Array(lines.prefix(40)), modified: raw.modified)
        }
}

struct SyncError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: Reminders

let store = EKEventStore()
let wait = DispatchSemaphore(value: 0)
var remindersGranted = false
store.requestFullAccessToReminders { ok, _ in
    remindersGranted = ok
    wait.signal()
}
wait.wait()

func fetch(_ predicate: NSPredicate) -> [EKReminder] {
    var found: [EKReminder] = []
    store.fetchReminders(matching: predicate) { reminders in
        found = reminders ?? []
        wait.signal()
    }
    wait.wait()
    return found
}

func fillReminders(_ board: inout Board) {
    guard remindersGranted else {
        board.remindersError = "Reminders access not granted"
        return
    }
    store.reset()  // drop cached reminders so edits show up on the next pass
    let calendar = Calendar.current
    let open = fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
    let doneToday = fetch(store.predicateForCompletedReminders(withCompletionDateStarting: calendar.startOfDay(for: Date()),
                                                               ending: Date(), calendars: nil))
    func due(_ r: EKReminder) -> Date? { r.dueDateComponents.flatMap { calendar.date(from: $0) } }
    board.todo = open
        .sorted { (due($0) ?? .distantFuture, $0.creationDate ?? .distantPast) < (due($1) ?? .distantFuture, $1.creationDate ?? .distantPast) }
        .prefix(12)
        .map { BoardTask(title: $0.title ?? "", list: $0.calendar.title, due: due($0)) }
    board.done = doneToday
        .sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        .prefix(8)
        .map { BoardTask(title: $0.title ?? "", list: $0.calendar.title, completed: $0.completionDate) }
}

// MARK: Loop

var lastSummary = ""
while true {
    autoreleasepool {
        var board = Board(updated: Date())
        do {
            board.notes = try fetchNotes()
        } catch {
            board.notesError = "\(error)"
        }
        fillReminders(&board)
        do {
            try board.save()
            let summary = "\(board.notes.count) notes, \(board.todo.count) to do, \(board.done.count) done"
            if summary != lastSummary {
                print("\(Date()): synced \(summary)")
                lastSummary = summary
            }
        } catch {
            fputs("\(Date()): write failed: \(error)\n", stderr)
        }
    }
    sleep(interval)
}
