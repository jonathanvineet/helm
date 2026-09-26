import SwiftUI

/// Primary flight display: attitude, speed/altitude tapes, VSI, heading, modes.
struct PFDView: View {
    let f: FlightState
    var body: some View {
        Canvas { ctx, size in PFD.draw(ctx, min(size.width, size.height), f) }
    }
}

enum PFD {
    static func draw(_ ctx: GraphicsContext, _ S: CGFloat, _ f: FlightState) {
        let c = CGPoint(x: S * 0.47, y: S * 0.47)
        let lw = max(1.2, S * 0.0035)
        attitude(ctx, S, c, f, lw)
        speedTape(ctx, S, c, f, lw)
        altitudeTape(ctx, S, c, f, lw)
        verticalSpeed(ctx, S, c, f, lw)
        headingArc(ctx, S, c, f, lw)
        modes(ctx, S, c)
    }

    static func attitude(_ ctx: GraphicsContext, _ S: CGFloat, _ c: CGPoint, _ f: FlightState, _ lw: CGFloat) {
        let rect = CGRect(x: c.x - S * 0.25, y: c.y - S * 0.26, width: S * 0.5, height: S * 0.52)
        let ppd = S * 0.018
        var a = ctx
        a.clip(to: Path(roundedRect: rect, cornerRadius: S * 0.04))
        a.translateBy(x: c.x, y: c.y)
        a.rotate(by: .degrees(-f.roll))

        var world = a
        world.translateBy(x: 0, y: f.pitch * ppd)
        let big = S * 2
        world.fill(Path(CGRect(x: -big, y: -big, width: 2 * big, height: big)),
                   with: .linearGradient(Gradient(colors: [Theme.skyTop, Theme.sky]),
                                         startPoint: CGPoint(x: 0, y: -S * 0.5), endPoint: .zero))
        world.fill(Path(CGRect(x: -big, y: 0, width: 2 * big, height: big)),
                   with: .linearGradient(Gradient(colors: [Theme.ground, Theme.groundDeep]),
                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: S * 0.5)))
        world.stroke(seg(CGPoint(x: -big, y: 0), CGPoint(x: big, y: 0)), with: .color(.white), lineWidth: lw * 1.2)

        var ladder = a
        ladder.clip(to: Path(roundedRect: CGRect(x: -S * 0.15, y: -S * 0.17, width: S * 0.3, height: S * 0.31),
                             cornerRadius: S * 0.06))
        ladder.translateBy(x: 0, y: f.pitch * ppd)
        for step in stride(from: -40.0, through: 40.0, by: 2.5) where step != 0 {
            let y = -step * ppd
            let major = step.truncatingRemainder(dividingBy: 10) == 0
            let mid = step.truncatingRemainder(dividingBy: 5) == 0
            let hw = major ? S * 0.07 : (mid ? S * 0.04 : S * 0.018)
            ladder.stroke(seg(CGPoint(x: -hw, y: y), CGPoint(x: hw, y: y)), with: .color(.white), lineWidth: lw)
            if major {
                let label = "\(Int(abs(step)))"
                txt(ladder, label, CGPoint(x: -hw - S * 0.01, y: y), S * 0.026, .white, .trailing)
                txt(ladder, label, CGPoint(x: hw + S * 0.01, y: y), S * 0.026, .white, .leading)
            }
        }

        // Roll scale (fixed) and sky pointer (rotates with the horizon).
        let r = S * 0.225
        ctx.stroke(arc(c, r, from: -60, to: 60), with: .color(.white), lineWidth: lw)
        for d in [-60.0, -45, -30, -20, -10, 10, 20, 30, 45, 60] {
            let len = abs(d) == 30 || abs(d) == 60 ? S * 0.03 : S * 0.017
            ctx.stroke(seg(polar(c, r, d), polar(c, r + len, d)), with: .color(.white), lineWidth: lw)
        }
        ctx.fill(poly([CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x - S * 0.014, y: c.y - r - S * 0.024),
                       CGPoint(x: c.x + S * 0.014, y: c.y - r - S * 0.024)]), with: .color(.white))
        a.stroke(poly([CGPoint(x: 0, y: -r + S * 0.003), CGPoint(x: -S * 0.014, y: -r + S * 0.026),
                       CGPoint(x: S * 0.014, y: -r + S * 0.026)]), with: .color(.white), lineWidth: lw)

        // Flight director.
        let fx = c.x + CGFloat(f.fdRoll) * S * 0.008
        let fy = c.y + CGFloat(f.fdPitch) * ppd
        ctx.stroke(seg(CGPoint(x: fx, y: c.y - S * 0.11), CGPoint(x: fx, y: c.y + S * 0.11)),
                   with: .color(Theme.magenta), lineWidth: lw * 1.6)
        ctx.stroke(seg(CGPoint(x: c.x - S * 0.11, y: fy), CGPoint(x: c.x + S * 0.11, y: fy)),
                   with: .color(Theme.magenta), lineWidth: lw * 1.6)

        // Aircraft symbol.
        let t = S * 0.014
        for side in [-1.0, 1.0] {
            let outer = c.x + side * S * 0.17, inner = c.x + side * S * 0.06
            let wing = poly([CGPoint(x: outer, y: c.y - t / 2), CGPoint(x: inner, y: c.y - t / 2),
                             CGPoint(x: inner, y: c.y + S * 0.035), CGPoint(x: inner - side * t, y: c.y + S * 0.035),
                             CGPoint(x: inner - side * t, y: c.y + t / 2), CGPoint(x: outer, y: c.y + t / 2)])
            ctx.fill(wing, with: .color(.black))
            ctx.stroke(wing, with: .color(Theme.amber), lineWidth: lw)
        }
        let dot = CGRect(x: c.x - t / 2, y: c.y - t / 2, width: t, height: t)
        ctx.fill(Path(dot), with: .color(.black))
        ctx.stroke(Path(dot), with: .color(Theme.amber), lineWidth: lw)
    }

    static func speedTape(_ ctx: GraphicsContext, _ S: CGFloat, _ c: CGPoint, _ f: FlightState, _ lw: CGFloat) {
        let r = CGRect(x: S * 0.04, y: S * 0.17, width: S * 0.12, height: S * 0.6)
        ctx.fill(Path(roundedRect: r, cornerRadius: S * 0.008), with: .color(Theme.tape))
        var tc = ctx
        tc.clip(to: Path(r))
        let ppk = r.height / 120
        let base = (f.ias / 10).rounded(.down) * 10
        for v in stride(from: base - 70, through: base + 70, by: 10) where v >= 0 {
            let y = c.y - (v - f.ias) * ppk
            tc.stroke(seg(CGPoint(x: r.maxX - S * 0.018, y: y), CGPoint(x: r.maxX, y: y)), with: .color(Theme.white), lineWidth: lw)
            if Int(v) % 20 == 0 {
                txt(tc, "\(Int(v))", CGPoint(x: r.maxX - S * 0.026, y: y), S * 0.032, Theme.white, .trailing)
            }
        }
        let sy = c.y - (f.selSpeed - f.ias) * ppk
        tc.stroke(Path(CGRect(x: r.maxX - S * 0.012, y: sy - S * 0.014, width: S * 0.012, height: S * 0.028)),
                  with: .color(Theme.magenta), lineWidth: lw * 1.3)
        tc.stroke(seg(CGPoint(x: r.maxX - S * 0.005, y: c.y), CGPoint(x: r.maxX - S * 0.005, y: c.y - f.speedTrend * ppk)),
                  with: .color(Theme.green), lineWidth: lw * 1.5)

        let box = pointerBox(CGRect(x: r.minX + S * 0.006, y: c.y - S * 0.032, width: r.width - S * 0.024, height: S * 0.064),
                             pointRight: true, notch: S * 0.012)
        ctx.fill(box, with: .color(.black))
        ctx.stroke(box, with: .color(.white), lineWidth: lw)
        txt(ctx, "\(Int(f.ias.rounded()))", CGPoint(x: r.minX + S * 0.054, y: c.y), S * 0.046, Theme.white, .center, .semibold)
        txt(ctx, "\(Int(f.selSpeed))", CGPoint(x: r.midX, y: r.minY - S * 0.024), S * 0.034, Theme.magenta)
        txt(ctx, String(format: ".%03d", Int((f.mach * 1000).rounded())), CGPoint(x: r.midX, y: r.maxY + S * 0.026), S * 0.034, Theme.white)
    }

    static func altitudeTape(_ ctx: GraphicsContext, _ S: CGFloat, _ c: CGPoint, _ f: FlightState, _ lw: CGFloat) {
        let r = CGRect(x: S * 0.755, y: S * 0.17, width: S * 0.13, height: S * 0.6)
        ctx.fill(Path(roundedRect: r, cornerRadius: S * 0.008), with: .color(Theme.tape))
        var tc = ctx
        tc.clip(to: Path(r))
        let ppf = r.height / 1200
        let base = (f.altitude / 100).rounded(.down) * 100
        for alt in stride(from: base - 700, through: base + 700, by: 100) {
            let y = c.y - (alt - f.altitude) * ppf
            tc.stroke(seg(CGPoint(x: r.minX, y: y), CGPoint(x: r.minX + S * 0.016, y: y)), with: .color(Theme.white), lineWidth: lw)
            if Int(alt) % 200 == 0 {
                txt(tc, "\(Int(alt))", CGPoint(x: r.minX + S * 0.022, y: y), S * 0.028, Theme.white, .leading)
            }
        }
        let sy = c.y - (f.selAlt - f.altitude) * ppf
        tc.stroke(Path(CGRect(x: r.minX, y: sy - S * 0.016, width: S * 0.012, height: S * 0.032)),
                  with: .color(Theme.magenta), lineWidth: lw * 1.3)

        let box = pointerBox(CGRect(x: r.minX + S * 0.012, y: c.y - S * 0.032, width: r.width - S * 0.008, height: S * 0.064),
                             pointRight: false, notch: S * 0.012)
        ctx.fill(box, with: .color(.black))
        ctx.stroke(box, with: .color(.white), lineWidth: lw)
        let shown = Int((f.altitude / 20).rounded()) * 20
        txt(ctx, "\(shown)", CGPoint(x: r.minX + S * 0.074, y: c.y), S * 0.036, Theme.white, .center, .semibold)
        txt(ctx, "\(Int(f.selAlt))", CGPoint(x: r.midX, y: r.minY - S * 0.024), S * 0.034, Theme.magenta)
        txt(ctx, "STD", CGPoint(x: r.midX, y: r.maxY + S * 0.026), S * 0.032, Theme.cyan)
    }

    static func verticalSpeed(_ ctx: GraphicsContext, _ S: CGFloat, _ c: CGPoint, _ f: FlightState, _ lw: CGFloat) {
        let r = CGRect(x: S * 0.9, y: S * 0.25, width: S * 0.045, height: S * 0.44)
        ctx.fill(Path(roundedRect: r, cornerRadius: S * 0.01), with: .color(Theme.tape))
        func vy(_ v: Double) -> CGFloat {
            let p = (1 - exp(-abs(v) / 1500)) * (v < 0 ? -1 : 1)
            return c.y - p * r.height * 0.48
        }
        for m in [-6000.0, -2000, -1000, -500, 0, 500, 1000, 2000, 6000] {
            let y = vy(m)
            let len = m == 0 ? S * 0.02 : S * 0.012
            ctx.stroke(seg(CGPoint(x: r.minX + S * 0.004, y: y), CGPoint(x: r.minX + S * 0.004 + len, y: y)),
                       with: .color(Theme.white), lineWidth: lw)
            if [1000.0, 2000, 6000].contains(abs(m)) {
                txt(ctx, "\(Int(abs(m) / 1000))", CGPoint(x: r.minX + S * 0.03, y: y), S * 0.024, Theme.white)
            }
        }
        var nc = ctx
        nc.clip(to: Path(r))
        nc.stroke(seg(CGPoint(x: r.maxX + S * 0.035, y: c.y), CGPoint(x: r.minX + S * 0.01, y: vy(f.vs))),
                  with: .color(Theme.white), lineWidth: lw * 1.6)
    }

    static func headingArc(_ ctx: GraphicsContext, _ S: CGFloat, _ c: CGPoint, _ f: FlightState, _ lw: CGFloat) {
        let hc = CGPoint(x: c.x, y: S * 1.3)
        let R = S * 0.46
        var hctx = ctx
        hctx.clip(to: Path(CGRect(x: c.x - S * 0.3, y: S * 0.838, width: S * 0.6, height: S * 0.17)))
        hctx.fill(Path(ellipseIn: CGRect(x: hc.x - R, y: hc.y - R, width: 2 * R, height: 2 * R)), with: .color(Theme.tape))
        for d in stride(from: 0, to: 360, by: 5) {
            let rel = wrap180(Double(d) - f.heading)
            guard abs(rel) < 42 else { continue }
            let major = d % 10 == 0
            hctx.stroke(seg(polar(hc, R, rel), polar(hc, R - (major ? S * 0.024 : S * 0.013), rel)),
                        with: .color(Theme.white), lineWidth: lw)
            if d % 30 == 0 {
                txt(hctx, "\(d / 10)", polar(hc, R - S * 0.05, rel), S * 0.034, Theme.white, .center, .semibold)
            } else if major {
                txt(hctx, "\(d / 10)", polar(hc, R - S * 0.048, rel), S * 0.024, Theme.white)
            }
        }
        let sel = wrap180(f.selHeading - f.heading)
        if abs(sel) < 42 {
            let p = polar(hc, R, sel)
            hctx.fill(poly([p, polar(hc, R - S * 0.02, sel - 1.6), polar(hc, R - S * 0.02, sel + 1.6)]), with: .color(Theme.magenta))
        }
        let top = hc.y - R
        ctx.fill(poly([CGPoint(x: c.x, y: top + S * 0.016), CGPoint(x: c.x - S * 0.012, y: top - S * 0.004),
                       CGPoint(x: c.x + S * 0.012, y: top - S * 0.004)]), with: .color(.white))

        let box = CGRect(x: c.x - S * 0.048, y: S * 0.782, width: S * 0.096, height: S * 0.046)
        ctx.fill(Path(box), with: .color(.black))
        ctx.stroke(Path(box), with: .color(.white), lineWidth: lw)
        txt(ctx, String(format: "%03d", Int(f.heading.rounded()) % 360), CGPoint(x: box.midX, y: box.midY), S * 0.038, Theme.white, .center, .semibold)
        txt(ctx, "MAG", CGPoint(x: box.maxX + S * 0.012, y: box.midY), S * 0.026, Theme.green, .leading)
        txt(ctx, String(format: "%03d H", Int(f.selHeading)), CGPoint(x: box.minX - S * 0.012, y: box.midY), S * 0.026, Theme.magenta, .trailing)
    }

    static func modes(_ ctx: GraphicsContext, _ S: CGFloat, _ c: CGPoint) {
        for x in [c.x - S * 0.095, c.x + S * 0.095] {
            ctx.stroke(seg(CGPoint(x: x, y: S * 0.025), CGPoint(x: x, y: S * 0.085)), with: .color(Theme.dim), lineWidth: 1)
        }
        let y = S * 0.055
        txt(ctx, "SPD", CGPoint(x: c.x - S * 0.19, y: y), S * 0.034, Theme.green, .center, .semibold)
        txt(ctx, "LNAV", CGPoint(x: c.x, y: y), S * 0.034, Theme.green, .center, .semibold)
        txt(ctx, "VNAV PTH", CGPoint(x: c.x + S * 0.19, y: y), S * 0.034, Theme.green, .center, .semibold)
        txt(ctx, "CMD", CGPoint(x: c.x, y: S * 0.13), S * 0.036, Theme.green, .center, .semibold)
    }
}
