import SwiftUI

/// Engine and crew alerting display, fed by real machine telemetry:
/// N1 = CPU / memory, EGT = load / thermal, fuel = battery.
struct EICASView: View {
    let tel: TelemetrySnapshot
    var body: some View {
        Canvas { ctx, size in EICAS.draw(ctx, min(size.width, size.height), tel) }
    }
}

enum EICAS {
    static func draw(_ ctx: GraphicsContext, _ S: CGFloat, _ tel: TelemetrySnapshot) {
        let lw = max(1.2, S * 0.0035)

        let n1y = S * 0.19, egty = S * 0.44
        dial(ctx, CGPoint(x: S * 0.27, y: n1y), S * 0.12, tel.cpu * 100 / 110, String(format: "%.1f", tel.cpu * 100), "CPU", S, lw)
        dial(ctx, CGPoint(x: S * 0.73, y: n1y), S * 0.12, tel.mem * 100 / 110, String(format: "%.1f", tel.mem * 100), "MEM", S, lw)
        txt(ctx, "N1", CGPoint(x: S * 0.5, y: n1y), S * 0.036, Theme.cyan, .center, .semibold)

        let loadFrac = tel.load1 / Double(max(tel.cores, 1))
        let (thermFrac, thermText): (Double, String) = switch tel.thermal {
        case .nominal: (0.35, "NOM")
        case .fair: (0.6, "FAIR")
        case .serious: (0.88, "HIGH")
        case .critical: (1.0, "CRIT")
        @unknown default: (0.35, "---")
        }
        dial(ctx, CGPoint(x: S * 0.27, y: egty), S * 0.085, min(1, loadFrac / 1.2), String(format: "%.2f", tel.load1), "LOAD", S, lw)
        dial(ctx, CGPoint(x: S * 0.73, y: egty), S * 0.085, thermFrac, thermText, "THERM", S, lw)
        txt(ctx, "EGT", CGPoint(x: S * 0.5, y: egty), S * 0.034, Theme.cyan, .center, .semibold)

        // Systems readout.
        let rows: [(String, String)] = [
            ("DLINK ▼", rate(tel.rxRate)),
            ("DLINK ▲", rate(tel.txRate)),
            ("MEM", String(format: "%.1f/%.0f GB", tel.memUsedGB, tel.memTotalGB)),
            ("UPTIME", uptime(tel.uptime)),
            ("DISK", String(format: "%.0f GB FREE", tel.diskFreeGB)),
        ]
        for (i, row) in rows.enumerated() {
            let y = S * (0.6 + 0.045 * Double(i))
            txt(ctx, row.0, CGPoint(x: S * 0.05, y: y), S * 0.027, Theme.cyan, .leading)
            txt(ctx, row.1, CGPoint(x: S * 0.52, y: y), S * 0.027, Theme.white, .trailing)
        }

        // Fuel = battery.
        let fb = CGRect(x: S * 0.58, y: S * 0.575, width: S * 0.37, height: S * 0.21)
        ctx.stroke(Path(roundedRect: fb, cornerRadius: S * 0.01), with: .color(Theme.dim), lineWidth: 1)
        txt(ctx, "FUEL", CGPoint(x: fb.minX + S * 0.02, y: fb.minY + S * 0.03), S * 0.028, Theme.cyan, .leading, .semibold)
        if let level = tel.battery {
            let low = level < 0.2 && !tel.onAC
            txt(ctx, "\(Int((level * 100).rounded()))%", CGPoint(x: fb.maxX - S * 0.02, y: fb.minY + S * 0.035), S * 0.05,
                low ? Theme.amber : Theme.white, .trailing, .semibold)
            let bar = CGRect(x: fb.minX + S * 0.02, y: fb.minY + S * 0.085, width: fb.width - S * 0.04, height: S * 0.03)
            ctx.stroke(Path(bar), with: .color(Theme.white.opacity(0.7)), lineWidth: 1)
            ctx.fill(Path(CGRect(x: bar.minX + 2, y: bar.minY + 2, width: max(0, (bar.width - 4) * level), height: bar.height - 4)),
                     with: .color(low ? Theme.amber : Theme.green))
            let state = tel.charging ? "CHARGING" : tel.onAC ? "EXT PWR" : "ON BATT"
            txt(ctx, state, CGPoint(x: fb.minX + S * 0.02, y: fb.maxY - S * 0.035), S * 0.027,
                tel.onAC ? Theme.green : Theme.white, .leading)
        } else {
            txt(ctx, "EXT PWR", CGPoint(x: fb.midX, y: fb.midY + S * 0.01), S * 0.042, Theme.green, .center, .semibold)
        }

        // Alerts: cautions (amber) then memos (white).
        ctx.stroke(seg(CGPoint(x: S * 0.04, y: S * 0.83), CGPoint(x: S * 0.96, y: S * 0.83)), with: .color(Theme.dim), lineWidth: 1)
        var messages: [(String, Color)] = []
        if tel.thermal == .serious || tel.thermal == .critical { messages.append(("ENG OVERHEAT", Theme.amber)) }
        if let b = tel.battery, b < 0.2, !tel.onAC { messages.append(("FUEL QTY LOW", Theme.amber)) }
        if tel.mem > 0.9 { messages.append(("MEMORY PRESSURE", Theme.amber)) }
        if tel.cpu > 0.9 { messages.append(("ENG 1 N1 HIGH", Theme.amber)) }
        messages.append(("AUTOPILOT CMD", Theme.white))
        messages.append(("SCREENSAVER ACTIVE", Theme.white))
        for (i, m) in messages.prefix(3).enumerated() {
            txt(ctx, m.0, CGPoint(x: S * 0.05, y: S * (0.87 + 0.042 * Double(i))), S * 0.03, m.1, .leading, .semibold)
        }
    }

    /// Boeing-style round gauge: 210° sweep, filled sector, redline, digital box.
    static func dial(_ ctx: GraphicsContext, _ c: CGPoint, _ r: CGFloat, _ frac: Double, _ value: String,
                     _ caption: String, _ S: CGFloat, _ lw: CGFloat) {
        let v = min(max(frac, 0), 1)
        let start = -90.0, sweep = 210.0
        let hot = v > 0.84
        ctx.fill(wedge(c, r, from: start, to: start + sweep * v), with: .color((hot ? Theme.amber : Color(white: 0.55)).opacity(0.45)))
        ctx.stroke(arc(c, r, from: start, to: start + sweep), with: .color(Theme.white), lineWidth: lw * 1.3)
        let red = start + sweep * 0.91
        ctx.stroke(seg(polar(c, r, red), polar(c, r * 1.18, red)), with: .color(Theme.red), lineWidth: lw * 2)
        ctx.stroke(seg(c, polar(c, r * 0.96, start + sweep * v)), with: .color(hot ? Theme.amber : Theme.white), lineWidth: lw * 2)

        let box = CGRect(x: c.x + r * 0.08, y: c.y - r * 0.82, width: r * 1.05, height: r * 0.42)
        ctx.fill(Path(box), with: .color(.black))
        ctx.stroke(Path(box), with: .color(Theme.white.opacity(0.85)), lineWidth: lw)
        txt(ctx, value, CGPoint(x: box.maxX - r * 0.08, y: box.midY), r * 0.3, hot ? Theme.amber : Theme.white, .trailing, .semibold)
        txt(ctx, caption, CGPoint(x: c.x, y: c.y + r * 0.55), S * 0.024, Theme.cyan)
    }

    static func uptime(_ s: TimeInterval) -> String {
        let total = Int(s)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        return d > 0 ? String(format: "%dd %02d:%02d", d, h, m) : String(format: "%02d:%02d", h, m)
    }
}
