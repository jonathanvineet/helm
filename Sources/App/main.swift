import AppKit
import SwiftUI

// Helm.app: menu bar agent. Keeps the screensaver's notes/reminders board in
// sync and hosts the Customize window.

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--write-iconset"), i + 1 < args.count {
    MainActor.assumeIsolated { Logo.writeIconset(to: args[i + 1]) }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let engine = SyncEngine()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Logo.menuBarImage()
        statusItem.button?.toolTip = "Helm"

        let menu = NSMenu()
        menu.delegate = self
        statusLine = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Customize…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Sync Now", action: #selector(syncNow), keyEquivalent: "r")
        menu.addItem(withTitle: "Start Screensaver", action: #selector(startScreensaver), keyEquivalent: "s")
        menu.addItem(withTitle: "Open Notes", action: #selector(openNotes), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Helm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu

        engine.start()
        log("Helm started")
    }

    func menuWillOpen(_ menu: NSMenu) {
        let notes = engine.board?.notes.count ?? 0
        let todo = engine.board?.todo.count ?? 0
        var line = "\(notes) note\(notes == 1 ? "" : "s") · \(todo) to do"
        if let updated = engine.board?.updated {
            line += " · synced " + updated.formatted(.relative(presentation: .named))
        }
        statusLine.title = line
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Helm"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(engine: engine))
            window.center()
            window.delegate = self
            settingsWindow = window
        }
        // Show in the Dock and app switcher while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func syncNow() { engine.syncNow() }

    @objc private func startScreensaver() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"),
                                           configuration: .init())
    }

    @objc private func openNotes() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Notes.app"), configuration: .init())
    }
}

/// Login launch via a LaunchAgent (installed by build.sh). Removing the file
/// turns it off from the next login.
enum LoginItem {
    static let label = "com.jonathanvineet.helm"
    static var plist: URL {
        URL(fileURLWithPath: realHome).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plist.path) }

    static func set(_ on: Bool) {
        if on {
            let dict: [String: Any] = [
                "Label": label,
                "ProgramArguments": [Bundle.main.executablePath ?? ""],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ProcessType": "Interactive",
                "StandardOutPath": realHome + "/Library/Logs/Helm.log",
                "StandardErrorPath": realHome + "/Library/Logs/Helm.log",
            ]
            (dict as NSDictionary).write(to: plist, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plist)
        }
    }
}
