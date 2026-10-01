import AppKit
import Foundation

// Source for the app's original glyph-based icon. No downloaded imagery.
let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 214, yRadius: 214).fill()
    let glyph = NSAttributedString(string: "₿", attributes: [
        .font: NSFont.systemFont(ofSize: 694, weight: .medium),
        .foregroundColor: NSColor(calibratedRed: 0.969, green: 0.576, blue: 0.102, alpha: 1)
    ])
    let glyphSize = glyph.size()
    glyph.draw(at: NSPoint(x: (1024 - glyphSize.width) / 2, y: (1024 - glyphSize.height) / 2 + 9))
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 {
        try data.write(to: target.appendingPathComponent("icon_\(size)x\(size).png"))
    }
    if size >= 32 {
        try data.write(to: target.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
