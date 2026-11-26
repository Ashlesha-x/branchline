import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)] {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = NSAffineTransform(); transform.scale(by: size / 1024); transform.concat()
    NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.72, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 205, yRadius: 205).fill()
    let path = NSBezierPath(); path.lineWidth = 45; path.lineCapStyle = .round
    path.move(to: NSPoint(x: 300,y: 250)); path.line(to: NSPoint(x: 300,y: 775))
    path.move(to: NSPoint(x: 300,y: 390)); path.curve(to: NSPoint(x: 714,y: 630), controlPoint1: NSPoint(x: 300,y: 570), controlPoint2: NSPoint(x: 714,y: 450)); path.line(to: NSPoint(x: 714,y: 775))
    NSColor.white.withAlphaComponent(0.9).setStroke(); path.stroke()
    for point in [NSPoint(x: 300,y: 250), NSPoint(x: 300,y: 775), NSPoint(x: 714,y: 775)] {
        NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 60, y: point.y - 60, width: 120, height: 120)).fill()
    }
    NSColor(calibratedRed: 0.42, green: 0.91, blue: 0.82, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 240,y: 330,width: 120,height: 120)).fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(name))
}
