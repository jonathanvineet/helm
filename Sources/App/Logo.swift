import AppKit

/// Helm's logo: the bat mark (Resources/logo-mask.png), with a ship's wheel
/// drawn in code as a fallback if the image is missing.
enum Logo {
    static let mask: NSImage? = Bundle.main.image(forResource: "logo-mask")

    /// The mask filled with a colour (or gradient), fitted into `rect`.
    static func drawMask(in rect: CGRect, fill: (CGRect) -> Void) {
        guard let mask, let cg = NSGraphicsContext.current?.cgContext,
              let cgMask = mask.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let aspect = mask.size.width / mask.size.height
        var r = rect
        if rect.width / rect.height > aspect {
            r.size.width = rect.height * aspect
            r.origin.x = rect.midX - r.width / 2
        } else {
            r.size.height = rect.width / aspect
            r.origin.y = rect.midY - r.height / 2
        }
        cg.saveGState()
        cg.clip(to: r, mask: cgMask)
        fill(r)
        cg.restoreGState()
    }

    /// The wheel as separate pieces (rim, spokes, handles, hub), centred in
    /// `rect`. Filling each piece on its own avoids overlaps cancelling out.
    static func wheelPieces(in rect: CGRect, bold: Bool = false) -> [NSBezierPath] {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var pieces: [NSBezierPath] = []

        let rim = NSBezierPath()
        rim.windingRule = .evenOdd
        let outer = bold ? 0.68 : 0.66, inner = bold ? 0.47 : 0.5
        rim.appendOval(in: CGRect(x: c.x - r * outer, y: c.y - r * outer, width: r * outer * 2, height: r * outer * 2))
        rim.appendOval(in: CGRect(x: c.x - r * inner, y: c.y - r * inner, width: r * inner * 2, height: r * inner * 2))
        pieces.append(rim)

        let w = r * (bold ? 0.075 : 0.055)
        let knobR = r * (bold ? 0.13 : 0.105)
        for k in 0..<8 {
            let a = CGFloat(k) * .pi / 4
            let dir = CGPoint(x: cos(a), y: sin(a)), perp = CGPoint(x: -dir.y, y: dir.x)
            let spoke = NSBezierPath()
            spoke.move(to: CGPoint(x: c.x + perp.x * w, y: c.y + perp.y * w))
            spoke.line(to: CGPoint(x: c.x + dir.x * r * 0.84 + perp.x * w, y: c.y + dir.y * r * 0.84 + perp.y * w))
            spoke.line(to: CGPoint(x: c.x + dir.x * r * 0.84 - perp.x * w, y: c.y + dir.y * r * 0.84 - perp.y * w))
            spoke.line(to: CGPoint(x: c.x - perp.x * w, y: c.y - perp.y * w))
            spoke.close()
            pieces.append(spoke)
            let knob = CGPoint(x: c.x + dir.x * r * 0.87, y: c.y + dir.y * r * 0.87)
            pieces.append(NSBezierPath(ovalIn: CGRect(x: knob.x - knobR, y: knob.y - knobR, width: knobR * 2, height: knobR * 2)))
        }
        let hub = r * (bold ? 0.22 : 0.19)
        pieces.append(NSBezierPath(ovalIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)))
        return pieces
    }

    /// Menu bar icon: a template image so macOS tints it for light/dark menus.
    static func menuBarImage() -> NSImage {
        // The bat is ~2.8:1, so give it a wide slot and let it fill the width.
        let size = mask == nil ? NSSize(width: 18, height: 18) : NSSize(width: 34, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            if mask != nil {
                drawMask(in: rect.insetBy(dx: 1, dy: 1)) { NSBezierPath(rect: $0).fill() }
            } else {
                wheelPieces(in: rect, bold: true).forEach { $0.fill() }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Full-colour app icon: gold wheel on a deep navy tile.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // Bare bat, no tile: steel gradient plus a soft shadow so it reads
            // on both light (Finder) and dark (Dock) backgrounds.
            if mask != nil, let cg = NSGraphicsContext.current?.cgContext {
                cg.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03,
                             color: NSColor.black.withAlphaComponent(0.45).cgColor)
                cg.beginTransparencyLayer(auxiliaryInfo: nil)
                let steel = NSGradient(colors: [NSColor(white: 0.85, alpha: 1), NSColor(white: 0.55, alpha: 1),
                                                NSColor(white: 0.32, alpha: 1)])
                drawMask(in: rect.insetBy(dx: size * 0.04, dy: size * 0.04)) { steel?.draw(in: $0, angle: -90) }
                cg.endTransparencyLayer()
                return true
            }
            let inset = rect.insetBy(dx: size * 0.1, dy: size * 0.1)
            let tile = NSBezierPath(roundedRect: inset, xRadius: inset.width * 0.225, yRadius: inset.width * 0.225)

            NSGraphicsContext.current?.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = size * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
            shadow.set()
            NSColor(red: 0.05, green: 0.12, blue: 0.24, alpha: 1).setFill()
            tile.fill()
            NSGraphicsContext.current?.restoreGraphicsState()

            let dark = mask != nil
            NSGradient(colors: dark
                ? [NSColor(white: 0.17, alpha: 1), NSColor(white: 0.08, alpha: 1)]
                : [NSColor(red: 0.09, green: 0.25, blue: 0.45, alpha: 1), NSColor(red: 0.03, green: 0.09, blue: 0.2, alpha: 1)])?
                .draw(in: tile, angle: -90)
            guard let cg = NSGraphicsContext.current?.cgContext else { return true }
            cg.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.02,
                         color: NSColor.black.withAlphaComponent(0.5).cgColor)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            if dark {
                let silver = NSGradient(colors: [NSColor(white: 0.9, alpha: 1), NSColor(white: 0.62, alpha: 1)])
                drawMask(in: inset.insetBy(dx: inset.width * 0.12, dy: inset.width * 0.12)) { silver?.draw(in: $0, angle: -90) }
            } else {
                let gold = NSGradient(colors: [NSColor(red: 1.0, green: 0.84, blue: 0.5, alpha: 1),
                                               NSColor(red: 0.89, green: 0.58, blue: 0.18, alpha: 1)])
                for piece in wheelPieces(in: inset.insetBy(dx: inset.width * 0.14, dy: inset.width * 0.14)) {
                    NSGraphicsContext.current?.saveGraphicsState()
                    piece.addClip()
                    gold?.draw(in: inset, angle: -90)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
            cg.endTransparencyLayer()
            return true
        }
    }

    /// Writes a .iconset folder for `iconutil`.
    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                rep.size = NSSize(width: px, height: px)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                appIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }
}
