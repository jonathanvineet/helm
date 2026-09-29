import AppKit
import SwiftUI

// helm-render out.png [seconds] [photo] [board.json]
// Draws one frame of the screensaver (current board.json, or the one given,
// over a photo) to a PNG.
let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: helm-render out.png [seconds] [photo] [board.json]\n", stderr)
    exit(1)
}

MainActor.assumeIsolated {
    let t = args.count > 2 ? Double(args[2]) ?? 5 : 5
    let photo = args.count > 3 ? NSImage(contentsOfFile: args[3]) : nil
    let size = CGSize(width: 1470, height: 956)
    let board = args.count > 4 ? loadBoard(args[4]) : Board.load()

    let scene = GlassStage(board: board, t: t, now: Date(), size: size) {
        if let photo {
            Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height).clipped()
        } else {
            LinearGradient(colors: [.purple, .blue, .teal, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

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

func loadBoard(_ path: String) -> Board? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(Board.self, from: data)
}
