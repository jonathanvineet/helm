import SwiftUI

struct CockpitSession {
    let start: Date
}

/// Live cockpit: drives `CockpitScene` from a 30 fps timeline.
struct CockpitView: View {
    let session: CockpitSession
    let topInset: CGFloat
    @ObservedObject var telemetry: Telemetry

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let tel = telemetry.snapshot
            GeometryReader { geo in
                CockpitScene(t: timeline.date.timeIntervalSince(session.start), now: timeline.date,
                             flight: FlightState(time: timeline.date.timeIntervalSinceReferenceDate, turbulence: tel.cpu),
                             tel: tel, size: geo.size, topInset: topInset)
            }
        }
        .ignoresSafeArea()
    }
}

/// One frame of the cockpit. `t` is seconds since the cockpit came online and
/// drives the power-up sequence.
struct CockpitScene: View {
    let t: Double
    let now: Date
    let flight: FlightState
    let tel: TelemetrySnapshot
    let size: CGSize
    let topInset: CGFloat

    var body: some View {
        let W = size.width, H = size.height
        let glareH = max(84, min(132, H * 0.12))
        let stripH = max(30, H * 0.036)
        let gap = max(12, W * 0.012)
        let avail = H - topInset - glareH - stripH - gap * 3
        let unit = max(100, min((W - gap * 4) / 3, avail))
        let flood = min(1, max(0, t / 0.9))
        let caution = tel.thermal == .serious || tel.thermal == .critical
            || (tel.battery.map { $0 < 0.2 } ?? false && !tel.onAC)

        ZStack {
            // Transparent: the screensaver shows through. A light edge vignette
            // keeps the chrome readable over bright savers.
            RadialGradient(colors: [.clear, .black.opacity(0.45)], center: .center,
                           startRadius: min(W, H) * 0.3, endRadius: max(W, H) * 0.75)
                .opacity(flood)

            VStack(spacing: 0) {
                Color.clear.frame(height: topInset)
                Glareshield(t: t, flight: flight, caution: caution, height: glareH, width: W)
                    .frame(height: glareH)
                Spacer(minLength: gap)
                HStack(spacing: gap) {
                    DisplayUnit(t: t, onAt: 0.8, size: unit, title: "PFD", test: "IRS ALIGN") {
                        PFDView(f: flight)
                    }
                    DisplayUnit(t: t, onAt: 1.15, size: unit, title: "ND", test: "FMC LOAD") {
                        NDView(f: flight, t: t, now: now)
                    }
                    DisplayUnit(t: t, onAt: 1.5, size: unit, title: "EICAS", test: "EEC SYNC") {
                        EICASView(tel: tel)
                    }
                }
                Spacer(minLength: gap)
                BottomStrip(t: t, now: now, host: tel.host, height: stripH)
                    .frame(height: stripH)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(.horizontal, gap)
                    .opacity(min(1, max(0, (t - 1.8) / 0.6)))
                Spacer(minLength: gap * 0.5)
            }
        }
        .frame(width: W, height: H)
    }
}

// MARK: - Glareshield / autopilot panel

struct Glareshield: View {
    let t: Double
    let flight: FlightState
    let caution: Bool
    let height: CGFloat
    let width: CGFloat

    var body: some View {
        let powered = t > 0.3
        let test = powered && t < 1.6
        let u = min(height * 0.8, width / 14)

        ZStack {
            UnevenRoundedRectangle(bottomLeadingRadius: height * 0.3, bottomTrailingRadius: height * 0.3)
                .fill(LinearGradient(colors: [Color(white: 0.04).opacity(0.75), Color(white: 0.12).opacity(0.6)], startPoint: .top, endPoint: .bottom))
                .opacity(min(1, max(0, t / 0.9)))
                .shadow(color: .black.opacity(0.8), radius: 18, y: 10)
                .padding(.horizontal, width * 0.015)

            HStack(spacing: u * 0.2) {
                MasterLight(text: "MASTER\nWARNING", color: Theme.red, lit: test, u: u)
                Spacer(minLength: 0)
                HStack(spacing: u * 0.16) {
                    MCPButton(label: "A/T ARM", lit: powered, u: u)
                    MCPWindow(label: "IAS/MACH", value: test ? "888" : "\(Int(flight.selSpeed))", powered: powered, u: u)
                    MCPButton(label: "VNAV", lit: powered, u: u)
                    MCPButton(label: "LNAV", lit: powered, u: u)
                    MCPWindow(label: "HEADING", value: test ? "888" : String(format: "%03d", Int(flight.selHeading)), powered: powered, u: u)
                    MCPWindow(label: "ALTITUDE", value: test ? "88888" : "\(Int(flight.selAlt))", powered: powered, u: u)
                    MCPWindow(label: "VERT SPD", value: test ? "+8888" : "     ", powered: powered, u: u)
                    MCPButton(label: "CMD A", lit: powered, u: u)
                    MCPButton(label: "CMD B", lit: test, u: u)
                }
                .padding(.horizontal, u * 0.25)
                .padding(.vertical, u * 0.12)
                .background(RoundedRectangle(cornerRadius: u * 0.1).fill(Color(white: 0.19)))
                .overlay(RoundedRectangle(cornerRadius: u * 0.1).stroke(Color.white.opacity(0.08)))
                Spacer(minLength: 0)
                MasterLight(text: "MASTER\nCAUTION", color: Theme.amber, lit: test || (powered && caution), u: u)
            }
            .padding(.horizontal, width * 0.035)
        }
    }
}

struct MCPWindow: View {
    let label: String
    let value: String
    let powered: Bool
    let u: CGFloat

    var body: some View {
        VStack(spacing: u * 0.06) {
            Text(label)
                .font(.system(size: u * 0.12, weight: .semibold))
                .foregroundStyle(Theme.label)
                .lineLimit(1)
                .fixedSize()
            Text(powered ? value : " ")
                .font(.system(size: u * 0.3, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.amber)
                .shadow(color: Theme.amber.opacity(0.6), radius: 4)
                .frame(minWidth: u * 1.05)
                .padding(.horizontal, u * 0.08)
                .padding(.vertical, u * 0.03)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.black))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.1)))
        }
    }
}

struct MCPButton: View {
    let label: String
    let lit: Bool
    let u: CGFloat

    var body: some View {
        VStack(spacing: u * 0.05) {
            Capsule()
                .fill(lit ? Theme.green : Color(white: 0.12))
                .frame(width: u * 0.42, height: u * 0.06)
                .shadow(color: lit ? Theme.green.opacity(0.9) : .clear, radius: 5)
            Text(label)
                .font(.system(size: u * 0.12, weight: .bold))
                .foregroundStyle(Color(white: 0.8))
        }
        .frame(width: u * 0.72, height: u * 0.5)
        .background(RoundedRectangle(cornerRadius: u * 0.06)
            .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.2)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: u * 0.06).stroke(Color.black.opacity(0.6)))
    }
}

struct MasterLight: View {
    let text: String
    let color: Color
    let lit: Bool
    let u: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: u * 0.12, weight: .heavy))
            .multilineTextAlignment(.center)
            .foregroundStyle(lit ? color : color.opacity(0.18))
            .shadow(color: lit ? color : .clear, radius: 8)
            .frame(width: u * 0.95, height: u * 0.55)
            .background(RoundedRectangle(cornerRadius: u * 0.06).fill(lit ? color.opacity(0.18) : Color(white: 0.08)))
            .overlay(RoundedRectangle(cornerRadius: u * 0.06).stroke(Color.white.opacity(0.1)))
    }
}

// MARK: - Display units

struct DisplayUnit<Content: View>: View {
    let t: Double
    let onAt: Double
    let size: CGFloat
    let title: String
    let test: String
    let content: Content

    init(t: Double, onAt: Double, size: CGFloat, title: String, test: String, @ViewBuilder content: () -> Content) {
        self.t = t
        self.onAt = onAt
        self.size = size
        self.title = title
        self.test = test
        self.content = content()
    }

    var body: some View {
        let inset = size * 0.035
        let screen = size - inset * 2
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.03)
                .fill(LinearGradient(colors: [Color(white: 0.2).opacity(0.8), Color(white: 0.1).opacity(0.7)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.03).stroke(Color.white.opacity(0.07)))
                .shadow(color: .black.opacity(0.7), radius: 12, y: 6)
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(Color(white: 0.28))
                    .overlay(Rectangle().fill(Color.black.opacity(0.5)).frame(width: inset * 0.4, height: 1))
                    .frame(width: inset * 0.4, height: inset * 0.4)
                    .offset(x: (i % 2 == 0 ? -1 : 1) * (size / 2 - inset / 2),
                            y: (i < 2 ? -1 : 1) * (size / 2 - inset / 2))
            }
            ZStack {
                Theme.glass.opacity(0.62)
                phase(screen)
                LinearGradient(colors: [.white.opacity(0.05), .clear, .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
            }
            .frame(width: screen, height: screen)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.012))
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func phase(_ s: CGFloat) -> some View {
        let p = t - onAt
        if p < 0 {
            Color.clear
        } else if p < 0.15 {
            Color.white.opacity(0.8 * (1 - p / 0.15))
        } else if p < 0.8 {
            TestPattern(title: title)
        } else if p < 2.3 {
            AlignScreen(title: title, test: test, progress: (p - 0.8) / 1.5)
        } else {
            content.frame(width: s, height: s).opacity(min(1, (p - 2.3) / 0.35))
        }
    }
}

struct TestPattern: View {
    let title: String
    var body: some View {
        Canvas { ctx, size in
            let colors = [Theme.white, Theme.amber, Theme.cyan, Theme.green, Theme.magenta, Theme.red, Theme.sky]
            let w = size.width / CGFloat(colors.count)
            for (i, c) in colors.enumerated() {
                ctx.fill(Path(CGRect(x: CGFloat(i) * w, y: 0, width: w + 1, height: size.height * 0.62)), with: .color(c.opacity(0.75)))
            }
            for i in 0..<16 {
                let g = Double(i) / 15
                ctx.fill(Path(CGRect(x: CGFloat(i) * size.width / 16, y: size.height * 0.62, width: size.width / 16 + 1,
                                     height: size.height * 0.13)), with: .color(Color(white: g)))
            }
            txt(ctx, "\(title) SELF TEST", CGPoint(x: size.width / 2, y: size.height * 0.86), size.width * 0.05, Theme.white, .center, .bold)
        }
    }
}

struct AlignScreen: View {
    let title: String
    let test: String
    let progress: Double

    private static let lines = ["DSP BUS ........ OK", "SYM GEN ........ OK", "ARINC 429 ...... OK",
                                "ADIRU 1/2/3 .... OK", "CRC ............ OK", "WATCHDOG ....... OK"]

    var body: some View {
        Canvas { ctx, size in
            let S = size.width
            txt(ctx, title, CGPoint(x: S * 0.06, y: S * 0.08), S * 0.045, Theme.cyan, .leading, .bold)
            let shown = Int(Double(Self.lines.count) * min(1, progress * 1.3))
            for i in 0..<shown {
                txt(ctx, Self.lines[i], CGPoint(x: S * 0.06, y: S * (0.18 + 0.055 * Double(i))), S * 0.034, Theme.green, .leading)
            }
            let blink = Int(progress * 12) % 2 == 0
            txt(ctx, test, CGPoint(x: S / 2, y: S * 0.66), S * 0.06, blink ? Theme.white : Theme.white.opacity(0.4), .center, .bold)
            let bar = CGRect(x: S * 0.2, y: S * 0.73, width: S * 0.6, height: S * 0.03)
            ctx.stroke(Path(bar), with: .color(Theme.white), lineWidth: 1.5)
            ctx.fill(Path(CGRect(x: bar.minX + 3, y: bar.minY + 3, width: (bar.width - 6) * min(1, progress), height: bar.height - 6)),
                     with: .color(Theme.green))
        }
    }
}

// MARK: - Bottom strip

struct BottomStrip: View {
    let t: Double
    let now: Date
    let host: String
    let height: CGFloat

    var body: some View {
        let utc = utcComponents(now)
        let local = Calendar.current.dateComponents([.hour, .minute], from: now)
        let block = Int(max(0, t))
        let fs = height * 0.42
        HStack(spacing: height * 0.8) {
            Text("HELM").font(.system(size: fs * 1.1, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.white)
            field("FLT", "HLM01", fs)
            Spacer()
            field("UTC", String(format: "%02d:%02d:%02dZ", utc.hour ?? 0, utc.minute ?? 0, utc.second ?? 0), fs)
            field("LCL", String(format: "%02d:%02d", local.hour ?? 0, local.minute ?? 0), fs)
            field("BLOCK", String(format: "%02d:%02d:%02d", block / 3600, block / 60 % 60, block % 60), fs)
            Spacer()
            field("A/C", host, fs)
        }
        .padding(.horizontal, height)
    }

    private func field(_ label: String, _ value: String, _ fs: CGFloat) -> some View {
        HStack(spacing: fs * 0.5) {
            Text(label).font(.system(size: fs * 0.8, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.label)
            Text(value).font(.system(size: fs, weight: .medium, design: .monospaced)).foregroundStyle(Theme.green)
                .lineLimit(1)
        }
    }
}
