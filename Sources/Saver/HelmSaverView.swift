import AppKit
import ScreenSaver
import SwiftUI
import os

private let log = Logger(subsystem: "com.jonathanvineet.helm.saver", category: "saver")

/// Helm as a real screensaver: a Ken Burns photo slideshow with your notes and
/// reminders on top. macOS 26 keeps its screensaver above every app window, so
/// being the screensaver is the only way to overlay one.
@objc(HelmSaverView)
final class HelmSaverView: ScreenSaverView {
    private let playback: Playback
    private let store: BoardStore
    /// legacyScreenSaver creates new views mid-screensaver without removing old
    /// ones. Only the newest draws.
    private static weak var current: HelmSaverView?
    /// When this view last started drawing.
    private var runningSince = Date()

    override init?(frame: NSRect, isPreview: Bool) {
        let session = isPreview ? SaverSession(start: Date(), seed: 1) : SaverSession.resume()
        playback = MainActor.assumeIsolated { Playback() }
        store = MainActor.assumeIsolated { BoardStore() }
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        MainActor.assumeIsolated {
            Slideshow.seed = session.seed
            let root = SaverRoot(start: session.start, slides: Slideshow.shared, playback: playback, store: store)
            let host = NSHostingView(rootView: root)
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
        }

        // legacyScreenSaver on macOS 14+ never tears saver views down, so they
        // keep animating after the screensaver ends. Pause instead of exiting:
        // if the host process dies, macOS relaunches it mid-screensaver.
        if !isPreview {
            let dnc = DistributedNotificationCenter.default()
            dnc.addObserver(self, selector: #selector(screensaverStopped), name: .init("com.apple.screensaver.willstop"),
                            object: nil, suspensionBehavior: .deliverImmediately)
            dnc.addObserver(self, selector: #selector(screensaverStopped), name: .init("com.apple.screensaver.didstop"),
                            object: nil, suspensionBehavior: .deliverImmediately)
            dnc.addObserver(self, selector: #selector(screensaverStarted), name: .init("com.apple.screensaver.didstart"),
                            object: nil, suspensionBehavior: .deliverImmediately)
            let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(heartbeat, forMode: .common)
            MainActor.assumeIsolated {
                Self.current?.setRunning(false, reason: "replaced by newer view")
                Self.current = self
            }
        }
    }

    required init?(coder: NSCoder) {
        playback = MainActor.assumeIsolated { Playback() }
        store = MainActor.assumeIsolated { BoardStore() }
        super.init(coder: coder)
    }

    override func startAnimation() {
        super.startAnimation()
        guard isPreview || Self.current === self else { return }
        setRunning(true, reason: "startAnimation")
    }

    override func stopAnimation() {
        super.stopAnimation()
        setRunning(false, reason: "stopAnimation")
    }

    override func animateOneFrame() {}

    /// The screensaver ends on user input, and macOS doesn't reliably tell a
    /// sandboxed saver that it stopped. So any keyboard/mouse input after we
    /// started drawing means the screensaver is over.
    private func tick() {
        guard playback.running else { return }
        SaverSession.heartbeat()
        store.refreshIfChanged()
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        let drawing = Date().timeIntervalSince(runningSince)
        if drawing > 2, idle + 1 < drawing {
            setRunning(false, reason: String(format: "input %.1fs ago, drawing for %.1fs", idle, drawing))
        }
    }

    @objc private func screensaverStopped(_ note: Notification) {
        setRunning(false, reason: note.name.rawValue)
    }

    @objc private func screensaverStarted(_ note: Notification) {
        guard Self.current === self else { return }
        setRunning(true, reason: note.name.rawValue)
    }

    private func setRunning(_ running: Bool, reason: String) {
        guard running != playback.running else { return }
        log.notice("view \(ObjectIdentifier(self).hashValue % 10000) \(running ? "resume" : "pause", privacy: .public) (\(reason, privacy: .public))")
        playback.running = running
        if running {
            runningSince = Date()
            store.refreshIfChanged()
        }
    }
}

/// Whether the saver is drawing. Paused, it renders nothing and costs no CPU.
@MainActor
final class Playback: ObservableObject {
    @Published var running = true
}

/// board.json as written by Helm Sync, reloaded when the file changes.
@MainActor
final class BoardStore: ObservableObject {
    @Published private(set) var board: Board?
    private var loadedStamp: Date?

    init() { refreshIfChanged() }

    func refreshIfChanged() {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: Board.fileURL.path))?[.modificationDate] as? Date
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp
        board = Board.load()
        if let board {
            log.notice("board loaded: \(board.notes.count) notes, \(board.todo.count) to do, \(board.done.count) done")
        } else {
            log.error("board not readable at \(Board.fileURL.path, privacy: .public)")
        }
    }
}

/// Survives the host process being relaunched mid-screensaver, so the cockpit
/// doesn't replay its power-up and the slideshow keeps its order.
struct SaverSession {
    let start: Date
    let seed: UInt64

    private static let defaults = UserDefaults.standard
    /// A new screensaver session starts if nothing has drawn for this long.
    private static let gap: TimeInterval = 20

    static func resume() -> SaverSession {
        let now = Date().timeIntervalSinceReferenceDate
        let alive = defaults.double(forKey: "helm.alive")
        if now - alive < gap, defaults.double(forKey: "helm.start") > 0 {
            log.notice("continuing session")
            return SaverSession(start: Date(timeIntervalSinceReferenceDate: defaults.double(forKey: "helm.start")),
                                seed: UInt64(bitPattern: Int64(defaults.integer(forKey: "helm.seed"))))
        }
        let session = SaverSession(start: Date(), seed: UInt64.random(in: 1...UInt64(Int64.max)))
        defaults.set(now, forKey: "helm.start")
        defaults.set(Int(Int64(bitPattern: session.seed)), forKey: "helm.seed")
        defaults.set(now, forKey: "helm.alive")
        log.notice("new session")
        return session
    }

    static func heartbeat() {
        defaults.set(Date().timeIntervalSinceReferenceDate, forKey: "helm.alive")
    }
}

struct SaverRoot: View {
    let start: Date
    @ObservedObject var slides: Slideshow
    @ObservedObject var playback: Playback
    @ObservedObject var store: BoardStore

    var body: some View {
        if playback.running {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                GeometryReader { geo in
                    let settings = store.board?.settings ?? HelmSettings()
                    GlassStage(board: store.board, t: t, now: timeline.date, size: geo.size) {
                        if settings.showPhotos {
                            KenBurns(slides: slides, t: t, size: geo.size,
                                     hold: max(3, settings.photoDuration), zoom: settings.zoomAmount)
                        } else {
                            Color.black
                        }
                    }
                }
            }
            .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
    }
}

/// Slow pan-and-zoom crossfading slideshow, like the system Ken Burns style.
struct KenBurns: View {
    @ObservedObject var slides: Slideshow
    let t: Double
    let size: CGSize
    var hold = 12.0
    var zoom = 1.0

    private var fade: Double { min(2, hold / 4) }

    var body: some View {
        let k = Int(t / hold)
        let local = t - Double(k) * hold
        ZStack {
            Color.black
            layer(k)
            if local > hold - fade {
                layer(k + 1).opacity((local - (hold - fade)) / fade)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    @ViewBuilder
    private func layer(_ k: Int) -> some View {
        if let image = slides.image(k) {
            // Each slide moves across its full on-screen life (hold + fade).
            let p = min(1, max(0, (t - Double(k) * hold + fade) / (hold + fade)))
            var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: k &* 2_654_435_761 &+ 1))
            let zoomIn = rng.next() > 0.5
            let s0 = 1 + (0.04 + rng.next() * 0.06) * zoom, s1 = 1 + (0.14 + rng.next() * 0.08) * zoom
            let dx = (rng.next() - 0.5) * 0.08 * zoom, dy = (rng.next() - 0.5) * 0.06 * zoom
            let scale = zoomIn ? s0 + (s1 - s0) * p : s1 - (s1 - s0) * p
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .offset(x: size.width * dx * (p - 0.5) * 2, y: size.height * dy * (p - 0.5) * 2)
        }
    }
}

struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9 : seed }
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 10_000) / 10_000
    }
}
