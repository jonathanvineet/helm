import AppKit
import SwiftUI

// helm-render out.png [t] [photo]
// Draws one frame of the cockpit over a photo, without touching the screen.
let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: helm-render out.png [seconds] [photo]\n", stderr)
    exit(1)
}

MainActor.assumeIsolated {
    let t = args.count > 2 ? Double(args[2]) ?? 30 : 30
    let photo = args.count > 3 ? NSImage(contentsOfFile: args[3]) : nil

    let sampler = TelemetrySampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    let tel = sampler.sample()
    let now = Date()
    let size = CGSize(width: 1470, height: 956)

    let scene = ZStack {
        if let photo {
            Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height).clipped()
        } else {
            LinearGradient(colors: [.purple, .blue, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        CockpitScene(t: t, now: now,
                     flight: FlightState(time: now.timeIntervalSinceReferenceDate, turbulence: tel.cpu),
                     tel: tel, size: size, topInset: 32)
    }
    .frame(width: size.width, height: size.height)

    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    guard let cg = renderer.cgImage else {
        fputs("render failed\n", stderr)
        exit(1)
    }
    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: args[1]))
    print("wrote \(args[1])")
}
