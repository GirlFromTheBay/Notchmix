// Draws the Notchmix app icon and writes an .iconset folder.
//   swift Scripts/make-icon.swift <output.iconset>
// build.sh runs this (and iconutil) only when Resources/AppIcon.icns is missing.
import AppKit

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)

    // macOS icon grid: an 824 pt rounded square centred on a 1024 pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor.black.setFill()
    shape.fill()
    context.restoreGState()

    context.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.42, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.52, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -90)

    // Three mixer faders at different levels.
    let levels: [CGFloat] = [0.72, 0.38, 0.58]
    let trackWidth: CGFloat = 56
    let trackHeight: CGFloat = 500
    let spacing: CGFloat = 190
    let firstX = body.midX - spacing
    let bottom = body.midY - trackHeight / 2

    for (index, level) in levels.enumerated() {
        let centerX = firstX + CGFloat(index) * spacing
        let track = CGRect(x: centerX - trackWidth / 2, y: bottom, width: trackWidth, height: trackHeight)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()

        let filled = CGRect(x: track.minX, y: track.minY, width: trackWidth, height: trackHeight * level)
        NSColor.white.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: filled, xRadius: trackWidth / 2, yRadius: trackWidth / 2).fill()

        let knob = CGRect(x: centerX - 62, y: filled.maxY - 62, width: 124, height: 124)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        context.restoreGState()
    }
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = drawIcon(pixels: points * scale)
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
