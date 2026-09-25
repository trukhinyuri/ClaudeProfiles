import AppKit

/// Draws profile icons: the icon of the locally installed Claude app with a colored label band.
/// Nothing from Claude.app is bundled with Claude Profiles; the base icon is read from the user's own copy.
public enum IconRenderer {
    public static let size = 1024

    public static func profileIcon(base: NSImage, label: String, color: NSColor) -> NSImage {
        render { rect in
            base.draw(in: rect)
            let band = NSRect(x: rect.width * 0.08, y: rect.height * 0.06, width: rect.width * 0.84, height: rect.height * 0.30)
            color.setFill()
            NSBezierPath(roundedRect: band, xRadius: rect.width * 0.07, yRadius: rect.width * 0.07).fill()
            drawCentered(label.uppercased(), in: band.insetBy(dx: band.width * 0.06, dy: 0), maxFontSize: rect.height * 0.22)
        }
    }

    /// Claude Profiles's own icon: a stack of three windows, one per subscription. Contains no third-party artwork.
    public static func appIcon() -> NSImage {
        render { rect in
            let s = rect.width
            let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
            let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
            NSGradient(starting: NSColor(hex: "#2B2F3A"), ending: NSColor(hex: "#14161C"))!.draw(in: tilePath, angle: -90)

            let cards: [(dx: CGFloat, dy: CGFloat, color: String)] = [(-0.13, 0.13, "#7048E8"), (0, 0, "#1971C2"), (0.13, -0.13, "#E8590C")]
            for card in cards {
                let frame = NSRect(x: s * (0.29 + card.dx), y: s * (0.33 + card.dy), width: s * 0.42, height: s * 0.34)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = s * 0.03
                shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
                shadow.set()
                let path = NSBezierPath(roundedRect: frame, xRadius: s * 0.05, yRadius: s * 0.05)
                NSGradient(starting: NSColor(hex: card.color).blended(withFraction: 0.18, of: .white)!,
                           ending: NSColor(hex: card.color))!.draw(in: path, angle: -90)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.85).setFill()
                for i in 0..<3 {
                    let dot = NSRect(x: frame.minX + s * (0.035 + CGFloat(i) * 0.04), y: frame.maxY - s * 0.06, width: s * 0.022, height: s * 0.022)
                    NSBezierPath(ovalIn: dot).fill()
                }
            }
        }
    }

    /// Fits `text` into `box` on one line, shrinking the font as needed.
    static func drawCentered(_ text: String, in box: NSRect, maxFontSize: CGFloat) {
        var fontSize = maxFontSize
        var attributes: [NSAttributedString.Key: Any] = [:]
        var textSize = NSSize.zero
        repeat {
            attributes = [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: NSColor.white]
            textSize = (text as NSString).size(withAttributes: attributes)
            fontSize *= 0.92
        } while textSize.width > box.width && fontSize > 8
        let origin = NSPoint(x: box.midX - textSize.width / 2, y: box.midY - textSize.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// Renders into an sRGB bitmap; safe to call off the main thread.
    static func render(_ draw: (NSRect) -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }

    /// Encodes an image as `.icns` (PNG payloads, 16 pt to 512 pt @2x).
    public static func icnsData(for image: NSImage) -> Data {
        let entries: [(String, Int)] = [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
                                        ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]
        var body = Data()
        for (type, pixels) in entries {
            guard let png = pngData(image, pixels: pixels) else { continue }
            body.append(Data(type.utf8))
            body.append(bigEndian(UInt32(png.count + 8)))
            body.append(png)
        }
        var file = Data("icns".utf8)
        file.append(bigEndian(UInt32(body.count + 8)))
        file.append(body)
        return file
    }

    public static func pngData(_ image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}

extension NSColor {
    /// `#RRGGBB` → sRGB color; falls back to gray for malformed input.
    public convenience init(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt32(digits, radix: 16) ?? 0x808080
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
