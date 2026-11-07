import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let background = NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960), xRadius: 215, yRadius: 215)
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.25, blue: 0.36, alpha: 1), ending: NSColor(srgbRed: 0.05, green: 0.09, blue: 0.19, alpha: 1))!.draw(in: background, angle: -65)
    for x: CGFloat in [160, 534] {
        let panel = NSBezierPath(roundedRect: NSRect(x: x, y: 285, width: 330, height: 500), xRadius: 42, yRadius: 42)
        NSColor.white.withAlphaComponent(0.09).setFill(); panel.fill()
        NSColor.white.withAlphaComponent(0.9).setStroke(); panel.lineWidth = 16; panel.stroke()
        let header = NSBezierPath(); header.move(to: NSPoint(x: x + 20, y: 680)); header.line(to: NSPoint(x: x + 310, y: 680)); header.lineWidth = 12; header.stroke()
        for y: CGFloat in [590, 510, 430] {
            NSColor(srgbRed: 0.32, green: 0.88, blue: 0.82, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 44, y: y, width: 34, height: 30), xRadius: 6, yRadius: 6).fill()
            NSColor.white.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 105, y: y + 8, width: 174, height: 14), xRadius: 7, yRadius: 7).fill()
        }
    }
    NSColor(srgbRed: 0.32, green: 0.88, blue: 0.82, alpha: 1).setStroke()
    let arrows = NSBezierPath(); arrows.lineWidth = 23; arrows.lineCapStyle = .round; arrows.lineJoinStyle = .round
    arrows.move(to: NSPoint(x: 305, y: 195)); arrows.line(to: NSPoint(x: 720, y: 195))
    arrows.move(to: NSPoint(x: 650, y: 250)); arrows.line(to: NSPoint(x: 720, y: 195)); arrows.line(to: NSPoint(x: 650, y: 140))
    arrows.move(to: NSPoint(x: 375, y: 250)); arrows.line(to: NSPoint(x: 305, y: 195)); arrows.line(to: NSPoint(x: 375, y: 140)); arrows.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if [16, 32, 128, 256, 512].contains(size) { try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [16, 32, 128, 256, 512].contains(size / 2) { try data.write(to: iconset.appendingPathComponent("icon_\(size / 2)x\(size / 2)@2x.png")) }
}
