import SwiftUI

/// Navigation display in map/arc mode: route, weather, traffic, radar sweep.
struct NDView: View {
    let f: FlightState
    let t: Double
    let now: Date
    var body: some View {
        Canvas { ctx, size in ND.draw(ctx, min(size.width, size.height), f, t, now) }
    }
}

enum ND {
    static let waypoints = ["BOTNY", "KAYLA", "MERIT", "ORCUS", "PELAX", "QUAIL", "RIDGE", "SOLAR",
                            "TANGO", "UMBRA", "VEXIL", "WAKER", "XENON", "YODEL", "ZAPPA"]
    /// along-track NM, lateral NM (right +), radius NM, intensity.
    static let cells: [(Double, Double, Double, Double)] = [
        (40, -34, 13, 0.9), (70, -26, 8, 0.5), (130, 42, 17, 1.0), (152, 58, 9, 0.4),
        (210, -62, 20, 0.8), (262, 24, 11, 0.6), (318, -18, 15, 0.9), (384, 70, 13, 0.5),
    ]
    static let spacing = 85.0
    static let range = 160.0
    static let span = 50.0

    static func draw(_ ctx: GraphicsContext, _ S: CGFloat, _ f: FlightState, _ t: Double, _ now: Date) {
        let ac = CGPoint(x: S * 0.5, y: S * 0.8)
        let R = S * 0.6
        let k = R / range
        let lw = max(1.2, S * 0.0035)
        let trackRel = wrap180(f.track - f.heading) * .pi / 180
        let u = CGPoint(x: sin(trackRel), y: -cos(trackRel))
        let v = CGPoint(x: cos(trackRel), y: sin(trackRel))
        func P(_ along: Double, _ lateral: Double) -> CGPoint {
            CGPoint(x: ac.x + k * (along * u.x + lateral * v.x), y: ac.y + k * (along * u.y + lateral * v.y))
        }

        var field = ctx
        field.clip(to: wedge(ac, R, from: -span, to: span))

        for (along0, lateral, radius, heat) in cells {
            var along = (along0 - f.distance).truncatingRemainder(dividingBy: 420)
            if along < 0 { along += 420 }
            along -= 30
            let p = P(along, lateral)
            let rr = radius * k
            let colors: [Color] = heat > 0.8
                ? [Theme.red.opacity(0.8), Theme.amber.opacity(0.75), Theme.green.opacity(0.45), .clear]
                : heat > 0.5 ? [Theme.amber.opacity(0.7), Theme.green.opacity(0.45), .clear]
                : [Theme.green.opacity(0.45), .clear]
            field.fill(Path(ellipseIn: CGRect(x: p.x - rr * 1.3, y: p.y - rr, width: rr * 2.6, height: rr * 2)),
                       with: .radialGradient(Gradient(colors: colors), center: p, startRadius: 0, endRadius: rr * 1.3))
        }

        // Radar sweep, back and forth with a fading trail.
        let phase = t * 0.9
        let sweep = span * sin(phase)
        let dir = cos(phase) >= 0 ? -1.0 : 1.0
        for i in 0..<16 {
            let a = sweep + dir * Double(i) * 1.1
            field.stroke(seg(ac, polar(ac, R, a)), with: .color(Theme.green.opacity(0.22 * (1 - Double(i) / 16))),
                         lineWidth: S * 0.006)
        }

        field.stroke(arc(ac, R / 2, from: -span, to: span), with: .color(Theme.white.opacity(0.6)),
                     style: StrokeStyle(lineWidth: lw, dash: [S * 0.012, S * 0.012]))
        txt(ctx, "\(Int(range / 2))", polar(ac, R / 2 + S * 0.02, -span - 4), S * 0.026, Theme.white)

        // Route with approaching waypoints.
        let into = f.distance.truncatingRemainder(dividingBy: spacing)
        let idx = Int((f.distance / spacing).rounded(.down))
        field.stroke(seg(ac, P(range + 40, 0)), with: .color(Theme.magenta), lineWidth: lw * 1.5)
        var nextName = ""
        var nextDist = 0.0
        for i in 0..<3 {
            let along = spacing * Double(i + 1) - into
            let p = P(along, 0)
            let color = i == 0 ? Theme.magenta : Theme.white
            let s = S * 0.018
            field.stroke(poly([CGPoint(x: p.x, y: p.y - s), CGPoint(x: p.x + s * 0.3, y: p.y - s * 0.3),
                               CGPoint(x: p.x + s, y: p.y), CGPoint(x: p.x + s * 0.3, y: p.y + s * 0.3),
                               CGPoint(x: p.x, y: p.y + s), CGPoint(x: p.x - s * 0.3, y: p.y + s * 0.3),
                               CGPoint(x: p.x - s, y: p.y), CGPoint(x: p.x - s * 0.3, y: p.y - s * 0.3)]),
                         with: .color(color), lineWidth: lw)
            let name = waypoints[(idx + i + 1) % waypoints.count]
            txt(field, name, CGPoint(x: p.x + S * 0.03, y: p.y), S * 0.028, color, .leading)
            if i == 0 { nextName = name; nextDist = along }
        }

        // Traffic.
        let traffic: [(Double, Double, String)] = [
            (24 + 4 * sin(t * 0.05), 12 + 2 * cos(t * 0.04), "+10"),
            (70 - (t * 0.6).truncatingRemainder(dividingBy: 90), -22, "-20"),
        ]
        for (along, lateral, label) in traffic where along > 2 {
            let p = P(along, lateral)
            let s = S * 0.016
            let diamond = poly([CGPoint(x: p.x, y: p.y - s), CGPoint(x: p.x + s, y: p.y),
                                CGPoint(x: p.x, y: p.y + s), CGPoint(x: p.x - s, y: p.y)])
            if along < 30 { field.fill(diamond, with: .color(Theme.cyan)) } else { field.stroke(diamond, with: .color(Theme.cyan), lineWidth: lw) }
            txt(field, label, CGPoint(x: p.x, y: label.hasPrefix("+") ? p.y - s * 1.9 : p.y + s * 1.9), S * 0.024, Theme.cyan)
        }

        // Compass arc.
        ctx.stroke(arc(ac, R, from: -span, to: span), with: .color(Theme.white), lineWidth: lw)
        for d in stride(from: 0, to: 360, by: 5) {
            let rel = wrap180(Double(d) - f.heading)
            guard abs(rel) <= span else { continue }
            let len = d % 10 == 0 ? S * 0.028 : S * 0.014
            ctx.stroke(seg(polar(ac, R, rel), polar(ac, R - len, rel)), with: .color(Theme.white), lineWidth: lw)
            if d % 30 == 0 && abs(rel) < span - 3 {
                txt(ctx, "\(d / 10)", polar(ac, R - S * 0.055, rel), S * 0.036, Theme.white, .center, .semibold)
            }
        }
        let sel = wrap180(f.selHeading - f.heading)
        if abs(sel) <= span {
            ctx.stroke(Path(CGRect(x: polar(ac, R, sel).x - S * 0.012, y: polar(ac, R, sel).y - S * 0.012,
                                   width: S * 0.024, height: S * 0.012)), with: .color(Theme.magenta), lineWidth: lw * 1.3)
        }
        let top = ac.y - R
        ctx.fill(poly([CGPoint(x: ac.x, y: top), CGPoint(x: ac.x - S * 0.014, y: top - S * 0.026),
                       CGPoint(x: ac.x + S * 0.014, y: top - S * 0.026)]), with: .color(.white))

        // Ownship.
        let a = S * 0.03
        ctx.stroke(poly([CGPoint(x: ac.x, y: ac.y - a), CGPoint(x: ac.x + a * 0.55, y: ac.y + a * 0.7),
                         CGPoint(x: ac.x - a * 0.55, y: ac.y + a * 0.7)]), with: .color(.white), lineWidth: lw * 1.5)

        // Heading box.
        let box = CGRect(x: ac.x - S * 0.055, y: S * 0.08, width: S * 0.11, height: S * 0.05)
        ctx.fill(Path(box), with: .color(.black))
        ctx.stroke(Path(box), with: .color(.white), lineWidth: lw)
        txt(ctx, String(format: "%03d", Int(f.heading.rounded()) % 360), CGPoint(x: box.midX, y: box.midY), S * 0.04, Theme.white, .center, .semibold)
        txt(ctx, "HDG", CGPoint(x: box.minX - S * 0.014, y: box.midY), S * 0.028, Theme.green, .trailing)
        txt(ctx, "MAG", CGPoint(x: box.maxX + S * 0.014, y: box.midY), S * 0.028, Theme.green, .leading)

        // Corner data.
        let l = S * 0.04
        txt(ctx, "GS \(Int(f.gs))", CGPoint(x: l, y: S * 0.05), S * 0.034, Theme.white, .leading, .semibold)
        txt(ctx, "TAS \(Int(f.tas))", CGPoint(x: l, y: S * 0.095), S * 0.028, Theme.white, .leading)
        txt(ctx, String(format: "%03d°/%d", Int(f.windDir), Int(f.windSpeed)), CGPoint(x: l, y: S * 0.14), S * 0.028, Theme.white, .leading)
        let wc = CGPoint(x: l + S * 0.03, y: S * 0.2)
        let wdir = wrap180(f.windDir + 180 - f.heading)
        let tip = polar(wc, S * 0.026, wdir)
        ctx.stroke(seg(polar(wc, S * 0.026, wdir + 180), tip), with: .color(Theme.white), lineWidth: lw * 1.3)
        ctx.fill(poly([tip, polar(tip, S * 0.014, wdir + 155), polar(tip, S * 0.014, wdir - 155)]), with: .color(Theme.white))

        let rgt = S * 0.96
        let eta = utcComponents(now.addingTimeInterval(nextDist / max(f.gs, 1) * 3600))
        txt(ctx, nextName, CGPoint(x: rgt, y: S * 0.05), S * 0.034, Theme.magenta, .trailing, .semibold)
        txt(ctx, String(format: "%02d%02d.%dz", eta.hour ?? 0, eta.minute ?? 0, (eta.second ?? 0) / 6),
            CGPoint(x: rgt, y: S * 0.095), S * 0.028, Theme.white, .trailing)
        txt(ctx, "\(Int(nextDist)) NM", CGPoint(x: rgt, y: S * 0.14), S * 0.028, Theme.white, .trailing)

        txt(ctx, "WXR", CGPoint(x: l, y: S * 0.92), S * 0.026, Theme.green, .leading)
        txt(ctx, "TFC", CGPoint(x: l, y: S * 0.96), S * 0.026, Theme.cyan, .leading)
        txt(ctx, "RNP 1.00", CGPoint(x: rgt, y: S * 0.92), S * 0.026, Theme.green, .trailing)
        txt(ctx, "ANP 0.04", CGPoint(x: rgt, y: S * 0.96), S * 0.026, Theme.green, .trailing)
    }
}
