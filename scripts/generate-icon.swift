import AppKit
import Foundation

// Original artwork made from basic shapes; no official Antigravity assets.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift OUTPUT.iconset\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(pixels: Int, destination: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "IconGeneration", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 198, yRadius: 198)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.32, alpha: 1), ending: NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.17, alpha: 1))!
    gradient.draw(in: tile, angle: -70)

    let orbit = NSBezierPath(ovalIn: NSRect(x: 235, y: 235, width: 554, height: 554))
    orbit.lineWidth = 30
    NSColor(calibratedRed: 0.27, green: 0.81, blue: 0.82, alpha: 0.35).setStroke()
    orbit.stroke()

    let route = NSBezierPath()
    route.move(to: NSPoint(x: 275, y: 340))
    route.line(to: NSPoint(x: 512, y: 660))
    route.line(to: NSPoint(x: 749, y: 440))
    route.lineWidth = 58
    route.lineCapStyle = .round
    route.lineJoinStyle = .round
    NSColor(calibratedRed: 0.40, green: 0.91, blue: 0.83, alpha: 1).setStroke()
    route.stroke()

    for point in [NSPoint(x: 275, y: 340), NSPoint(x: 512, y: 660), NSPoint(x: 749, y: 440)] {
        let node = NSBezierPath(ovalIn: NSRect(x: point.x - 60, y: point.y - 60, width: 120, height: 120))
        NSColor.white.setFill()
        node.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 2)
    }
    try data.write(to: destination)
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, destination: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(pixels: size * 2, destination: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
