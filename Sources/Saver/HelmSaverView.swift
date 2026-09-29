import AppKit
import QuartzCore
import ScreenSaver
import SwiftUI
import os

private let log = Logger(subsystem: "com.jonathanvineet.helm.saver", category: "saver")

/// Helm as a real screensaver: a Ken Burns photo slideshow with your notes and
/// reminders on frosted glass on top. macOS 26 keeps its screensaver above every
/// app window, so being the screensaver is the only way to overlay one.
///
/// Photo motion and the glass blur run as Core Animation (in the window server,
/// on the GPU), so they stay smooth on every display however busy this process
/// is. Only the board's text is SwiftUI, redrawn once a second.
@objc(HelmSaverView)
final class HelmSaverView: ScreenSaverView {
    private let session: SaverSession
    private let store: BoardStore
    private let sharp = SlideStage()
    private let frosted = SlideStage()
    private let photoView = NSView()
    private let frostView = NSView()
    private let frostMask = CAShapeLayer()
    private var boardHost: NSView?
    private var panels: [PanelRect] = []

    private var running = false
    private var runningSince = Date()
    private var shownSlide: Int?
    private var blurRadius: Double = -1

    /// legacyScreenSaver creates one view per display at start, and later adds
    /// duplicates mid-screensaver without removing the old ones. Every window
    /// claims to be on the main screen, so displays are told apart by size and
    /// timing: a same-size view arriving well after another replaces it.
    private static var live: [WeakSaver] = []
    private let createdAt = Date()
    private var superseded = false

    override init?(frame: NSRect, isPreview: Bool) {
        session = isPreview ? SaverSession(start: Date(), seed: 1, isNew: true) : SaverSession.resume()
        store = MainActor.assumeIsolated { BoardStore() }
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        for view in [photoView, frostView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            addSubview(view)
        }
        frostView.layerUsesCoreImageFilters = true
        sharp.attach(to: photoView.layer!)
        frosted.attach(to: frostView.layer!)
        frostView.layer?.mask = frostMask

        MainActor.assumeIsolated {
            Slideshow.seed = session.seed
            let host = NSHostingView(rootView: BoardOverlay(store: store) { [weak self] rects in
                self?.panels = rects
                self?.updateMask()
            })
            host.frame = bounds
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            boardHost = host
        }

        if !isPreview {
            let dnc = DistributedNotificationCenter.default()
            dnc.addObserver(self, selector: #selector(screensaverStopped), name: .init("com.apple.screensaver.willstop"),
                            object: nil, suspensionBehavior: .deliverImmediately)
            dnc.addObserver(self, selector: #selector(screensaverStopped), name: .init("com.apple.screensaver.didstop"),
                            object: nil, suspensionBehavior: .deliverImmediately)
            dnc.addObserver(self, selector: #selector(screensaverStarted), name: .init("com.apple.screensaver.didstart"),
                            object: nil, suspensionBehavior: .deliverImmediately)
        }
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        setRunning(true, reason: "created")
    }

    required init?(coder: NSCoder) {
        session = SaverSession(start: Date(), seed: 1, isNew: true)
        store = MainActor.assumeIsolated { BoardStore() }
        super.init(coder: coder)
    }

    override func startAnimation() {
        super.startAnimation()
        if isCurrent { setRunning(true, reason: "startAnimation") }
    }

    override func stopAnimation() {
        super.stopAnimation()
        setRunning(false, reason: "stopAnimation")
    }

    override func animateOneFrame() {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sharp.fit(to: photoView.bounds)
        frosted.fit(to: frostView.bounds)
        CATransaction.commit()
        updateMask()
    }

    /// On an automatic start, legacyScreenSaver sometimes builds the second
    /// display's window (or our view) at the main screen's size and never
    /// resizes it, leaving the board in one corner. Stretch the window over the
    /// display it actually sits on, and ourselves over the window. The view is
    /// often attached before its container has a size, so empty frames are
    /// ignored rather than copied.
    private func fitToDisplay() {
        guard !isPreview, let window else { return }
        let wf = window.frame
        log.notice("window \(String(describing: wf), privacy: .public), container \(String(describing: self.superview?.bounds), privacy: .public), view \(String(describing: self.frame), privacy: .public)")
        if area(wf) > 0, !NSScreen.screens.contains(where: { $0.frame == wf }),
           let screen = NSScreen.screens.max(by: { area($0.frame.intersection(wf)) < area($1.frame.intersection(wf)) }),
           area(screen.frame.intersection(wf)) > 0 {
            log.notice("window resized to screen \(String(describing: screen.frame), privacy: .public)")
            window.setFrame(screen.frame, display: true)
        }
        fillContainer()
    }

    private func fillContainer() {
        guard !isPreview, let superview, area(superview.bounds) > 0, frame != superview.bounds else { return }
        log.notice("view \(String(describing: self.frame), privacy: .public) resized to \(String(describing: superview.bounds), privacy: .public)")
        frame = superview.bounds
    }

    /// Always match the container once it has a size, instead of autoresizing,
    /// which carries over any mismatch (or a 0×0 start) forever.
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        guard !isPreview, let superview, area(superview.bounds) > 0 else {
            return super.resize(withOldSuperviewSize: oldSize)
        }
        fillContainer()
    }

    private func area(_ r: NSRect) -> CGFloat { r.isNull || r.isEmpty ? 0 : r.width * r.height }

    @objc private func windowChanged(_ note: Notification) { fitToDisplay() }

    // MARK: One view per display

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !isPreview, let window else { return }
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
        nc.removeObserver(self, name: NSWindow.didMoveNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didResizeNotification, object: window)
        nc.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didMoveNotification, object: window)
        fitToDisplay()
        // legacyScreenSaver may still be positioning the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.fitToDisplay() }
        Self.live.removeAll { $0.view == nil }
        for other in Self.live.compactMap(\.view)
        where other !== self && !other.superseded && other.bounds.size == bounds.size
            && createdAt.timeIntervalSince(other.createdAt) > 1.5 {
            other.superseded = true
            other.setRunning(false, reason: "replaced by a newer view of the same display")
        }
        if !Self.live.contains(where: { $0.view === self }) { Self.live.append(WeakSaver(view: self)) }
        log.notice("view \(Int(self.bounds.width))x\(Int(self.bounds.height)) attached; \(Self.live.count) live")
    }

    private var isCurrent: Bool { !superseded }

    // MARK: Running and pausing

    /// The screensaver ends on user input, and macOS doesn't reliably tell a
    /// sandboxed saver that it stopped. So any keyboard/mouse input after we
    /// started drawing means the screensaver is over.
    private func tick() {
        guard running else { return }
        if !isPreview {
            SaverSession.heartbeat()
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let drawing = Date().timeIntervalSince(runningSince)
            if drawing > 2, idle + 1 < drawing {
                setRunning(false, reason: String(format: "input %.1fs ago", idle))
                return
            }
        }
        store.refreshIfChanged()
        advanceSlides()
    }

    @objc private func screensaverStopped(_ note: Notification) {
        setRunning(false, reason: note.name.rawValue)
    }

    @objc private func screensaverStarted(_ note: Notification) {
        if isCurrent { setRunning(true, reason: note.name.rawValue) }
    }

    private func setRunning(_ on: Bool, reason: String) {
        guard on != running else { return }
        log.notice("\(on ? "resume" : "pause", privacy: .public) (\(reason, privacy: .public))")
        running = on
        if on {
            runningSince = Date()
            store.refreshIfChanged()
            boardHost?.isHidden = false
            if session.isNew && Date().timeIntervalSince(session.start) < 2 {
                boardHost?.alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 1.2; boardHost?.animator().alphaValue = 1 }
            }
            advanceSlides()
        } else {
            sharp.clear()
            frosted.clear()
            shownSlide = nil
            boardHost?.isHidden = true
        }
    }

    // MARK: Slideshow (Core Animation)

    private func advanceSlides() {
        let s = store.board?.settings ?? HelmSettings()
        applyBlur(s.glassBlur)
        guard s.showPhotos else {
            sharp.clear()
            frosted.clear()
            shownSlide = nil
            return
        }
        let hold = max(3, s.photoDuration)
        let t = Date().timeIntervalSince(session.start)
        let k = Int(t / hold)
        guard k != shownSlide, let image = MainActor.assumeIsolated({ Slideshow.shared.image(k) }),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        // First slide of a (resumed) session picks up mid-motion; later ones crossfade in.
        let first = shownSlide == nil
        let elapsed = first ? t - Double(k) * hold : 0
        let fade = first ? 0 : min(2, hold / 4)
        let motion = Motion(slide: k, zoom: s.zoomAmount)
        sharp.show(cg, motion: motion, duration: hold + fade, elapsed: elapsed, fade: fade)
        frosted.show(cg, motion: motion, duration: hold + fade, elapsed: elapsed, fade: fade)
        shownSlide = k
    }

    private func applyBlur(_ radius: Double) {
        guard radius != blurRadius else { return }
        blurRadius = radius
        frostView.isHidden = radius < 0.5
        let blur = CIFilter(name: "CIGaussianBlur")!
        blur.setValue(radius, forKey: kCIInputRadiusKey)
        let color = CIFilter(name: "CIColorControls")!
        color.setValue(1.25, forKey: kCIInputSaturationKey)
        frosted.root.filters = [blur, color]
    }

    /// The frosted copy only shows through the glass panels.
    private func updateMask() {
        let h = bounds.height
        let path = CGMutablePath()
        for p in panels {
            // SwiftUI frames are top-left based; this layer is bottom-left.
            let r = CGRect(x: p.rect.minX, y: h - p.rect.maxY, width: p.rect.width, height: p.rect.height)
            path.addRoundedRect(in: r, cornerWidth: p.radius, cornerHeight: p.radius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frostMask.frame = frostView.bounds
        frostMask.path = path
        CATransaction.commit()
    }
}

private struct WeakSaver {
    weak var view: HelmSaverView?
}

/// Pan and zoom for one slide, seeded by its index so every display (and a
/// relaunched host) moves the same way. Translation is a fraction of the
/// layer's size; SlideStage converts it to points.
struct Motion {
    let from: CATransform3D
    let to: CATransform3D

    init(slide k: Int, zoom: Double) {
        var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: k &* 2_654_435_761 &+ 1))
        let zoomIn = rng.next() > 0.5
        let s0 = 1 + (0.04 + rng.next() * 0.06) * zoom, s1 = 1 + (0.14 + rng.next() * 0.08) * zoom
        let dx = (rng.next() - 0.5) * 0.08 * zoom, dy = (rng.next() - 0.5) * 0.06 * zoom
        func t(_ scale: Double, _ p: Double) -> CATransform3D {
            var m = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
            m.m41 = CGFloat(dx * (p * 2 - 1))
            m.m42 = CGFloat(dy * (p * 2 - 1))
            return m
        }
        from = t(zoomIn ? s0 : s1, 0)
        to = t(zoomIn ? s1 : s0, 1)
    }
}

/// A stack of photo layers that crossfade, each slowly panning and zooming.
final class SlideStage {
    let root = CALayer()
    private var currentLayer: CALayer?

    func attach(to parent: CALayer) {
        root.frame = parent.bounds
        root.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.masksToBounds = true
        parent.addSublayer(root)
    }

    func show(_ image: CGImage, motion: Motion, duration: Double, elapsed: Double, fade: Double) {
        func points(_ t: CATransform3D) -> CATransform3D {
            var m = t
            m.m41 *= root.bounds.width
            m.m42 *= root.bounds.height
            return m
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layer = CALayer()
        layer.frame = root.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.contents = image
        layer.contentsGravity = .resizeAspectFill

        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = points(motion.from)
        move.toValue = points(motion.to)
        move.duration = duration
        move.beginTime = CACurrentMediaTime() - elapsed
        move.fillMode = .both
        move.isRemovedOnCompletion = false
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        layer.add(move, forKey: "kenburns")

        if fade > 0 {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.duration = fade
            appear.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(appear, forKey: "fade")
        }
        root.addSublayer(layer)
        CATransaction.commit()

        let old = currentLayer
        currentLayer = layer
        if let old {
            DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.1) { old.removeFromSuperlayer() }
        }
    }

    /// Layer autoresizing doesn't reliably follow a layer-backed view's
    /// resize, so the view resizes the stage explicitly.
    func fit(to bounds: CGRect) {
        guard root.frame != bounds else { return }
        root.frame = bounds
        root.sublayers?.forEach { $0.frame = bounds }
    }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        currentLayer = nil
    }
}

// MARK: - Board (SwiftUI, redrawn once a second)

struct PanelRect: Equatable {
    let rect: CGRect
    let radius: CGFloat
}

struct PanelRectsKey: PreferenceKey {
    static let defaultValue: [PanelRect] = []
    static func reduce(value: inout [PanelRect], nextValue: () -> [PanelRect]) { value += nextValue() }
}

/// Notes and reminders, reporting where the glass panels are so the frosted
/// photo layer can show through exactly there.
struct BoardOverlay: View {
    @ObservedObject var store: BoardStore
    let onPanels: ([PanelRect]) -> Void

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 1)) { tl in
                BoardView(board: store.board, t: 100, now: tl.date, size: geo.size)
            }
            .backgroundPreferenceValue(GlassPanelsKey.self) { panels in
                GeometryReader { g in
                    Color.clear.preference(key: PanelRectsKey.self,
                                           value: panels.map { PanelRect(rect: g[$0.anchor], radius: $0.radius) })
                }
            }
            .onPreferenceChange(PanelRectsKey.self) { onPanels($0) }
        }
        .ignoresSafeArea()
    }
}

/// board.json as written by Helm.app, reloaded when the file changes.
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
        if board == nil { log.error("board not readable at \(Board.fileURL.path, privacy: .public)") }
    }
}

/// Survives the host process being relaunched mid-screensaver, so the board
/// doesn't fade in again and the slideshow keeps its order and place.
struct SaverSession {
    let start: Date
    let seed: UInt64
    let isNew: Bool

    private static let defaults = UserDefaults.standard
    /// A new screensaver session starts if nothing has drawn for this long.
    private static let gap: TimeInterval = 20

    static func resume() -> SaverSession {
        let now = Date().timeIntervalSinceReferenceDate
        let alive = defaults.double(forKey: "helm.alive")
        if now - alive < gap, defaults.double(forKey: "helm.start") > 0 {
            return SaverSession(start: Date(timeIntervalSinceReferenceDate: defaults.double(forKey: "helm.start")),
                                seed: UInt64(bitPattern: Int64(defaults.integer(forKey: "helm.seed"))), isNew: false)
        }
        let session = SaverSession(start: Date(), seed: UInt64.random(in: 1...UInt64(Int64.max)), isNew: true)
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
