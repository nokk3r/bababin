import AppKit
import Foundation

private enum Palette {
    static let bgTop = NSColor(calibratedRed: 0.14, green: 0.14, blue: 0.16, alpha: 1)
    static let bgBottom = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1)
    static let orange = NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.10, alpha: 1)
    static let ring = NSColor(calibratedWhite: 1.0, alpha: 0.14)
}

private let baseWidth = 680.0
private let baseHeight = 440.0

private enum Layout {
    static let appIcon = NSPoint(x: 122, y: 170)
    static let appsIcon = NSPoint(x: 462, y: 170)
    static let iconSize: CGFloat = 96

    static var appCenter: NSPoint {
        NSPoint(x: appIcon.x + iconSize / 2, y: appIcon.y + iconSize / 2)
    }

    static var appsCenter: NSPoint {
        NSPoint(x: appsIcon.x + iconSize / 2, y: appsIcon.y + iconSize / 2)
    }
}

private func drawBackground(in rect: NSRect) {
    let gradient = NSGradient(colors: [Palette.bgTop, Palette.bgBottom])!
    gradient.draw(in: rect, angle: 270)

    let glow = NSGradient(colors: [
        Palette.orange.withAlphaComponent(0.12),
        Palette.orange.withAlphaComponent(0),
    ])!
    glow.draw(
        in: NSRect(x: rect.midX - 220, y: rect.height * 0.28, width: 440, height: rect.height * 0.44),
        relativeCenterPosition: NSPoint(x: 0.5, y: 0.5)
    )
}

private func drawDropTargets(scale: CGFloat) {
    let radius = 58 * scale
    for center in [Layout.appCenter, Layout.appsCenter] {
        let scaled = NSPoint(x: center.x * scale, y: center.y * scale)
        let circle = NSBezierPath(
            ovalIn: NSRect(
                x: scaled.x - radius,
                y: scaled.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        circle.lineWidth = 1.2 * scale
        Palette.ring.setStroke()
        circle.stroke()
    }
}

private func drawDragArrow(from start: NSPoint, to end: NSPoint, scale: CGFloat) {
    let lift = 18 * scale
    let control = NSPoint(x: (start.x + end.x) / 2, y: start.y + lift)

    let path = NSBezierPath()
    path.move(to: start)
    path.curve(to: end, controlPoint1: control, controlPoint2: control)
    path.lineWidth = 2.5 * scale
    path.lineCapStyle = .round
    Palette.orange.withAlphaComponent(0.85).setStroke()
    path.stroke()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x - 12 * scale, y: end.y + 6 * scale))
    head.line(to: NSPoint(x: end.x, y: end.y))
    head.line(to: NSPoint(x: end.x - 12 * scale, y: end.y - 6 * scale))
    head.lineWidth = 2.5 * scale
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    Palette.orange.setStroke()
    head.stroke()
}

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: render_dmg_background.swift <output.png> [scale]\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let scale = CommandLine.arguments.count >= 3 ? (Double(CommandLine.arguments[2]) ?? 1) : 1
let width = baseWidth * scale
let height = baseHeight * scale

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width),
    pixelsHigh: Int(height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("failed to allocate bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let rect = NSRect(x: 0, y: 0, width: width, height: height)
drawBackground(in: rect)
drawDropTargets(scale: scale)

let arrowY = Layout.appCenter.y * scale
drawDragArrow(
    from: NSPoint(x: (Layout.appCenter.x + 58) * scale, y: arrowY),
    to: NSPoint(x: (Layout.appsCenter.x - 58) * scale, y: arrowY),
    scale: scale
)

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else {
    fputs("failed to encode png\n", stderr)
    exit(1)
}
do {
    try data.write(to: outputURL)
} catch {
    fputs("failed to write png: \(error)\n", stderr)
    exit(1)
}
