import Foundation

/// The bridge from Helm's browser extension (extension/watcher) to the board.
///
/// Brave/Chrome start Helm's own binary as a native messaging host whenever the
/// extension sends its watch list. The host only saves that list to
/// `BoardWatch.fileURL`, pokes the running Helm.app to sync, and exits. Only the
/// Helm extension's ID is allowed to start it.
enum NativeHost {
    static let name = "com.jonathanvineet.helm"
    /// Fixed by the `key` in extension/manifest.json.
    static let extensionID = "popaljneofbfhillkaogepicefmnmdll"
    static let changed = Notification.Name("com.jonathanvineet.helm.watchesChanged")

    /// Browsers start the host with the calling extension's origin as an argument.
    static func isInvocation(_ args: [String]) -> Bool {
        args.dropFirst().contains { $0.hasPrefix("chrome-extension://") }
    }

    /// Reads one message from stdin, handles it, replies on stdout.
    static func run() -> Never {
        let stdin = FileHandle.standardInput
        guard let header = try? stdin.read(upToCount: 4), header.count == 4 else { exit(0) }
        let length = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        guard length <= 1_000_000, let body = try? stdin.read(upToCount: Int(length)), body.count == Int(length) else {
            reply(["ok": false])
            exit(1)
        }
        var ok = false
        if let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           message["type"] as? String == "watcher:board",
           let raw = message["watches"] as? [[String: Any]] {
            let source = (message["source"] as? String).map { String($0.prefix(64)) } ?? "default"
            ok = (try? save(raw.compactMap(BoardWatch.init(message:)), from: source)) != nil
            if ok { DistributedNotificationCenter.default().postNotificationName(changed, object: nil, deliverImmediately: true) }
        }
        reply(["ok": ok])
        exit(0)
    }

    private static func reply(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        var length = UInt32(data.count).littleEndian
        FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
        FileHandle.standardOutput.write(data)
    }

    /// Replaces one profile's watches. Profiles can send at the same moment, so
    /// the read-modify-write is done under a lock.
    private static func save(_ watches: [BoardWatch], from source: String) throws {
        let url = BoardWatch.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lock = open(url.path + ".lock", O_CREAT | O_RDWR, 0o644)
        guard lock >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(lock) }
        flock(lock, LOCK_EX)
        defer { flock(lock, LOCK_UN) }

        var store = BoardWatch.Store.read()
        store.sources[source] = .init(updated: Date(), watches: watches)
        try store.write()
    }

    /// Registers the host with each installed Chromium browser, pointing at
    /// this copy of Helm. Run at every launch so a moved or updated app still works.
    static func install() {
        guard let executable = Bundle.main.executablePath else { return }
        let manifest: [String: Any] = [
            "name": name,
            "description": "Helm: shows watched pages on the screensaver",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        let support = URL(fileURLWithPath: realHome).appendingPathComponent("Library/Application Support")
        for browser in ["BraveSoftware/Brave-Browser", "Google/Chrome", "Chromium", "Microsoft Edge", "Arc/User Data"] {
            let dir = support.appendingPathComponent(browser)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let hosts = dir.appendingPathComponent("NativeMessagingHosts")
            let file = hosts.appendingPathComponent("\(name).json")
            if (try? Data(contentsOf: file)) == data { continue }
            try? FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}

extension BoardWatch {
    /// One watch as the extension sends it (times in milliseconds).
    init?(message m: [String: Any]) {
        guard let name = m["name"] as? String, !name.isEmpty else { return nil }
        func date(_ key: String) -> Date? {
            (m[key] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        }
        self.init(name: String(name.prefix(80)),
                  text: String((m["text"] as? String ?? "").prefix(300)),
                  quoted: m["quoted"] as? Bool ?? false,
                  state: (m["state"] as? String).flatMap(State.init(rawValue:)) ?? .watching,
                  since: date("since"),
                  checked: date("checked"))
    }
}
