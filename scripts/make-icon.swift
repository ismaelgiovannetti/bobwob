// Draws the app icon and writes it as an .icns file.
// Usage: swift scripts/make-icon.swift packaging/AppIcon.icns
import AppKit

func renderIcon(pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Impossible de créer l'image")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: scale, y: scale)

    // macOS icons sit on an 824 pt rounded square centered in a 1024 pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGradient(
        starting: NSColor(srgbRed: 0.20, green: 0.27, blue: 0.95, alpha: 1),
        ending: NSColor(srgbRed: 0.05, green: 0.08, blue: 0.32, alpha: 1)
    )?.draw(in: shape, angle: -90)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let font = NSFont.systemFont(ofSize: 400, weight: .black)
    let text = NSAttributedString(string: "BW", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph,
        .kern: -14,
    ])
    let height = text.size().height
    text.draw(in: NSRect(x: tile.minX, y: tile.midY - height / 2, width: tile.width, height: height))

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Impossible d'encoder le PNG")
    }
    return png
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage : make-icon.swift <sortie.icns>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("BobWob-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for size in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try renderIcon(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", output.path, iconset.path]
try process.run()
process.waitUntilExit()
exit(process.terminationStatus)
