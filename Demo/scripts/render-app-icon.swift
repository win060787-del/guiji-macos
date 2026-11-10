import AppKit

// Legacy ICNS needs its own silhouette; unlike Icon Composer layers it isn't system-masked.
let source = CommandLine.arguments[1]
let destination = CommandLine.arguments[2]
guard let artwork = NSImage(contentsOfFile: source),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render app icon") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high
let bounds = NSRect(x: 100, y: 100, width: 824, height: 824)
let silhouette = NSBezierPath(roundedRect: bounds, xRadius: 184, yRadius: 184)
NSShadow().set()
context.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
shadow.shadowBlurRadius = 14
shadow.shadowOffset = NSSize(width: 0, height: -7)
shadow.set()
NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
silhouette.fill()
context.restoreGraphicsState()
silhouette.addClip()
artwork.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
// A restrained specular wash and inner rim, without changing the ink mark.
if let sheen = NSGradient(starting: NSColor.white.withAlphaComponent(0.30), ending: NSColor.white.withAlphaComponent(0.0)) {
    sheen.draw(in: silhouette, angle: 270)
}
let rim = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 182, yRadius: 182)
NSColor.white.withAlphaComponent(0.80).setStroke()
rim.lineWidth = 3
rim.stroke()
let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.8, dy: 0.8), xRadius: 183, yRadius: 183)
NSColor.black.withAlphaComponent(0.08).setStroke()
edge.lineWidth = 1.5
edge.stroke()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode app icon") }
try png.write(to: URL(fileURLWithPath: destination), options: .atomic)
