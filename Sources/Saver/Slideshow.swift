import AppKit
import ImageIO

/// Photos for the slideshow. Uses the folder picked for the system slideshow
/// when the sandbox allows reading it, otherwise the copy bundled at build time.
@MainActor
final class Slideshow: ObservableObject {
    /// Set before first use of `shared`; fixes the photo order for a session.
    static var seed: UInt64 = 1
    static let shared = Slideshow()

    private let urls: [URL]
    private var cache: [Int: NSImage] = [:]
    private var loading: Set<Int> = []

    private init() {
        let exts: Set<String> = ["jpg", "jpeg", "png", "heic", "tiff", "webp"]
        func list(_ dir: URL) -> [URL] {
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return items.filter { exts.contains($0.pathExtension.lowercased()) }
        }
        var found: [URL] = []
        if let folder = Self.chosenFolder() { found = list(folder) }
        if found.isEmpty, let bundled = Bundle(for: HelmSaverView.self).url(forResource: "Photos", withExtension: nil) {
            found = list(bundled)
        }
        // Seeded shuffle, so a relaunched host shows the photos in the same order.
        var rng = SeededRandom(seed: Self.seed)
        var ordered = found.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for i in stride(from: ordered.count - 1, to: 0, by: -1) {
            ordered.swapAt(i, min(i, Int(rng.next() * Double(i + 1))))
        }
        urls = ordered
    }

    /// Image for slide `k`, or nil while it loads. Also warms the next slides.
    func image(_ k: Int) -> NSImage? {
        guard !urls.isEmpty else { return nil }
        let i = k % urls.count
        for ahead in [i, (i + 1) % urls.count, (i + 2) % urls.count] { load(ahead) }
        cache = cache.filter { key, _ in [i, (i + 1) % urls.count, (i + 2) % urls.count, (i + urls.count - 1) % urls.count].contains(key) }
        return cache[i]
    }

    private func load(_ i: Int) {
        guard cache[i] == nil, !loading.contains(i) else { return }
        loading.insert(i)
        let url = urls[i]
        let maxPixels = Int((NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }.max() ?? 3000) * 1.25)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = Self.downsample(url, maxPixels: maxPixels)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading.remove(i)
                    if let image {
                        self.cache[i] = image
                        self.objectWillChange.send()
                    }
                }
            }
        }
    }

    private nonisolated static func downsample(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// The folder chosen in System Settings for the photo slideshow.
    private static func chosenFolder() -> URL? {
        // Inside the screensaver sandbox NSHomeDirectory() is a container, so
        // resolve the real home directory.
        guard let pw = getpwuid(getuid()) else { return nil }
        let home = URL(fileURLWithPath: String(cString: pw.pointee.pw_dir))
        let byHost = home.appendingPathComponent("Library/Preferences/ByHost")
        let prefs = (try? FileManager.default.contentsOfDirectory(at: byHost, includingPropertiesForKeys: nil)) ?? []
        if let plist = prefs.first(where: { $0.lastPathComponent.hasPrefix("com.apple.ScreenSaverPhotoChooser.") }),
           let dict = NSDictionary(contentsOf: plist),
           let path = dict["SelectedFolderPath"] as? String {
            return URL(fileURLWithPath: path)
        }
        return home.appendingPathComponent("Downloads/wallpaper")
    }
}
