import SwiftUI

enum Theme {
    static let green = Color(red: 0.30, green: 1.0, blue: 0.45)
    static let cyan = Color(red: 0.35, green: 0.88, blue: 1.0)
    static let magenta = Color(red: 1.0, green: 0.38, blue: 1.0)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.15)
    static let red = Color(red: 1.0, green: 0.24, blue: 0.2)
    static let white = Color(white: 0.94)
    static let dim = Color(white: 0.5)
    static let label = Color(white: 0.62)
    static let sky = Color(red: 0.18, green: 0.5, blue: 0.9)
    static let skyTop = Color(red: 0.04, green: 0.2, blue: 0.52)
    static let ground = Color(red: 0.56, green: 0.34, blue: 0.14)
    static let groundDeep = Color(red: 0.28, green: 0.16, blue: 0.06)
    static let tape = Color(white: 0.2).opacity(0.85)
    static let glass = Color(red: 0.012, green: 0.016, blue: 0.022)
}

/// A calm cruise at FL360, generated from wall-clock time so it's continuous
/// across frames. CPU load shows up as turbulence.
struct FlightState {
    var pitch = 0.0, roll = 0.0, heading = 0.0, track = 0.0
    var ias = 0.0, mach = 0.0, tas = 0.0, gs = 0.0, speedTrend = 0.0
    var altitude = 0.0, vs = 0.0
    var windDir = 0.0, windSpeed = 0.0
    var distance = 0.0
    var fdRoll = 0.0, fdPitch = 0.0
    var selHeading = 0.0
    let selSpeed = 280.0
    let selAlt = 36000.0

    init(time T: Double, turbulence: Double) {
        let chop = 0.25 + min(1, turbulence) * 2.0
        let n1 = sin(T * 1.7) * sin(T * 0.43)
        let n2 = sin(T * 2.3 + 1) * cos(T * 0.61)
        let n3 = sin(T * 0.9 + 2) * sin(T * 0.27)

        heading = wrap360(272 + 24 * sin(T * 0.009))
        let turnRate = 24 * 0.009 * cos(T * 0.009) * .pi / 180
        let bank = atan(245 * turnRate / 9.81) * 180 / .pi
        roll = bank + chop * n1 * 1.2
        pitch = 2.4 + 0.3 * sin(T * 0.05) + chop * n2 * 0.35
        fdRoll = -chop * n1 * 1.2
        fdPitch = -chop * n2 * 0.35

        altitude = 36000 + 40 * sin(T * 0.023) + chop * n3 * 18
        vs = 40 * 0.023 * cos(T * 0.023) * 60 + chop * n2 * 60
        ias = 280 + 2.5 * sin(T * 0.041) + chop * n3 * 1.6
        speedTrend = 2.5 * 0.041 * cos(T * 0.041) * 10 + chop * n1 * 2
        mach = 0.82 * ias / 280
        tas = 474 * ias / 280

        windDir = wrap360(295 + 8 * sin(T * 0.013))
        windSpeed = 48 + 6 * sin(T * 0.017)
        let rel = (windDir - heading) * .pi / 180
        track = wrap360(heading - asin(windSpeed * sin(rel) / tas) * 180 / .pi)
        gs = tas - windSpeed * cos(rel)
        distance = T * 460 / 3600
        selHeading = wrap360((272 + 24 * sin((T + 40) * 0.009)).rounded())
    }
}

// MARK: - Drawing helpers

func wrap360(_ d: Double) -> Double {
    let x = d.truncatingRemainder(dividingBy: 360)
    return x < 0 ? x + 360 : x
}

func wrap180(_ d: Double) -> Double { wrap360(d + 180) - 180 }

func seg(_ a: CGPoint, _ b: CGPoint) -> Path {
    var p = Path()
    p.move(to: a)
    p.addLine(to: b)
    return p
}

func poly(_ pts: [CGPoint]) -> Path {
    var p = Path()
    p.addLines(pts)
    p.closeSubpath()
    return p
}

/// Point on a circle in compass terms: 0° is up, angles grow clockwise.
func polar(_ c: CGPoint, _ r: CGFloat, _ deg: Double) -> CGPoint {
    let th = deg * .pi / 180
    return CGPoint(x: c.x + r * CGFloat(sin(th)), y: c.y - r * CGFloat(cos(th)))
}

func arc(_ c: CGPoint, _ r: CGFloat, from a: Double, to b: Double) -> Path {
    let steps = max(8, Int(abs(b - a) / 2))
    var p = Path()
    p.addLines((0...steps).map { polar(c, r, a + (b - a) * Double($0) / Double(steps)) })
    return p
}

func wedge(_ c: CGPoint, _ r: CGFloat, from a: Double, to b: Double) -> Path {
    let steps = max(8, Int(abs(b - a) / 2))
    return poly([c] + (0...steps).map { polar(c, r, a + (b - a) * Double($0) / Double(steps)) })
}

func txt(_ ctx: GraphicsContext, _ s: String, _ p: CGPoint, _ size: CGFloat, _ color: Color,
         _ anchor: UnitPoint = .center, _ weight: Font.Weight = .medium) {
    ctx.draw(Text(s).font(.system(size: size, weight: weight, design: .monospaced)).foregroundStyle(color),
             at: p, anchor: anchor)
}

/// Readout box with a pointer notch on one side, like a tape's current-value window.
func pointerBox(_ r: CGRect, pointRight: Bool, notch: CGFloat) -> Path {
    let cy = r.midY
    if pointRight {
        return poly([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                     CGPoint(x: r.maxX, y: cy - notch), CGPoint(x: r.maxX + notch, y: cy),
                     CGPoint(x: r.maxX, y: cy + notch), CGPoint(x: r.maxX, y: r.maxY),
                     CGPoint(x: r.minX, y: r.maxY)])
    }
    return poly([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                 CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                 CGPoint(x: r.minX, y: cy + notch), CGPoint(x: r.minX - notch, y: cy),
                 CGPoint(x: r.minX, y: cy - notch)])
}

func utcComponents(_ date: Date) -> DateComponents {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.dateComponents([.hour, .minute, .second], from: date)
}

func rate(_ bytesPerSecond: Double) -> String {
    switch bytesPerSecond {
    case ..<1_000: return String(format: "%.0f B/s", bytesPerSecond)
    case ..<1_000_000: return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    default: return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
    }
}
