import AppKit
import CryptoKit

/// Checks GitHub for a newer Helm release and installs it in place: Helm.app
/// wherever it's running from, and Helm.saver wherever it's installed. Checks
/// quietly once a day; the menu offers the update when there is one.
@MainActor
final class Updater {
    static let shared = Updater()
    static let repo = "jonathanvineet/helm"

    struct Release {
        let version: String
        let zip: URL
        let sha256: String?
        let notes: String
        let page: URL
    }

    /// The newer release found by the last check, if any.
    private(set) var available: Release?
    private(set) var installing = false
    /// Called when `available` or `installing` changes, to refresh the menu.
    var onChange: (() -> Void)?
    private var busy = false
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check(interactive: false) }
        }
        Task {
            try? await Task.sleep(for: .seconds(30))
            await check(interactive: false)
        }
    }

    /// Interactive checks say when Helm is up to date and offer to install.
    func check(interactive: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let release: Release
        do {
            release = try await Self.latest()
        } catch {
            log("Update check failed: \(error.localizedDescription)")
            if interactive { alert("Couldn't check for updates", error.localizedDescription) }
            return
        }
        available = Self.isNewer(release.version, than: Self.currentVersion) ? release : nil
        onChange?()
        guard interactive else { return }
        guard let release = available else {
            alert("Helm is up to date", "You have the latest version, \(Self.currentVersion).")
            return
        }
        guard confirm(release) else { return }

        installing = true
        onChange?()
        do {
            try await install(release)
            log("Updated to \(release.version), relaunching")
            relaunch()
        } catch {
            log("Update failed: \(error.localizedDescription)")
            installing = false
            onChange?()
            alert("Couldn't install Helm \(release.version)", error.localizedDescription)
        }
    }

    private func confirm(_ release: Release) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Helm \(release.version) is available"
        var info = "You have \(Self.currentVersion). Helm will install the update and relaunch."
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { info += "\n\n" + String(notes.prefix(600)) }
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Release Notes")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return true
        case .alertThirdButtonReturn: NSWorkspace.shared.open(release.page); return false
        default: return false
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Fetching

    private static func latest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("GitHub answered with status \(status).") }

        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Payload: Decodable { let tag_name: String; let body: String?; let html_url: URL; let assets: [Asset] }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        guard let asset = payload.assets.first(where: { $0.name == "Helm-\(version).zip" }) else {
            throw UpdateError("The \(version) release has no Helm-\(version).zip.")
        }
        // GitHub records a "sha256:<hex>" digest for each uploaded asset.
        let sha256 = asset.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
        return Release(version: version, zip: asset.browser_download_url, sha256: sha256,
                       notes: payload.body ?? "", page: payload.html_url)
    }

    nonisolated static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Installing

    private func install(_ release: Release) async throws {
        // Stage on the app's volume so swapping it in is a rename.
        let stage = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: Bundle.main.bundleURL, create: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        let (download, response) = try await URLSession.shared.download(from: release.zip)
        defer { try? FileManager.default.removeItem(at: download) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError("The download failed with status \(status).") }
        try await Task.detached {
            try Self.unpack(download, into: stage, release: release)
            try Self.swap(from: stage)
        }.value
    }

    nonisolated private static func unpack(_ zip: URL, into stage: URL, release: Release) throws {
        if let expected = release.sha256 {
            let actual = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard actual == expected.lowercased() else { throw UpdateError("The download didn't match its checksum.") }
        }
        try run("/usr/bin/ditto", "-x", "-k", zip.path, stage.path)
        let app = stage.appendingPathComponent("Helm.app")
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == release.version else {
            throw UpdateError("The download doesn't contain Helm \(release.version).")
        }
        try run("/usr/bin/codesign", "--verify", "--deep", "--strict", app.path)
        try run("/usr/bin/xattr", "-cr", stage.path)
    }

    nonisolated private static func swap(from stage: URL) throws {
        let files = FileManager.default
        _ = try files.replaceItemAt(Bundle.main.bundleURL, withItemAt: stage.appendingPathComponent("Helm.app"))
        for dir in [realHome + "/Library/Screen Savers", "/Library/Screen Savers"] {
            let saver = URL(fileURLWithPath: dir).appendingPathComponent("Helm.saver")
            guard files.fileExists(atPath: saver.path) else { continue }
            do {
                _ = try files.replaceItemAt(saver, withItemAt: stage.appendingPathComponent("Helm.saver"))
            } catch {
                log("Couldn't update \(saver.path): \(error.localizedDescription)")
            }
            return
        }
    }

    /// Opens the new copy as a separate instance, then quits this one.
    private func relaunch() {
        try? Self.run("/usr/bin/killall", "legacyScreenSaver")  // load the new saver next time
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { log("Relaunch failed: \(error.localizedDescription)") }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\(process.executableURL!.lastPathComponent) failed (\(process.terminationStatus)).")
        }
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
