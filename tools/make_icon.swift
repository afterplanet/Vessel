// Draws the temporary app icon from the satellite SVG. Usage: swift tools/make_icon.swift <output.png>
import AppKit

let size = 1024.0
let svgURL = URL(fileURLWithPath: "Sources/Vessel/Resources/satellite.svg")
guard let satellite = NSImage(contentsOf: svgURL) else { fatalError("no satellite.svg") }
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
shape.addClip()
NSGradient(colors: [NSColor(red: 0.02, green: 0.05, blue: 0.16, alpha: 1), NSColor(red: 0.05, green: 0.16, blue: 0.38, alpha: 1)])!.draw(in: tile, angle: 90)

// A few stars.
NSColor.white.withAlphaComponent(0.75).setFill()
for (x, y, r) in [(190.0, 790.0, 5.0), (300, 860, 3.5), (760, 850, 5.0), (850, 700, 3.5), (640, 800, 3.0), (170, 610, 3.5), (830, 520, 4.0)] {
    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
}

// The Earth rising from the lower left, with a thin atmosphere.
let earth = NSRect(x: -260, y: -560, width: 1000, height: 1000)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: NSColor(red: 0.3, green: 0.65, blue: 1, alpha: 0.95).cgColor)
NSColor(red: 0.1, green: 0.4, blue: 0.85, alpha: 1).setFill()
NSBezierPath(ovalIn: earth).fill()
ctx.restoreGState()
let globe = NSBezierPath(ovalIn: earth)
NSGradient(colors: [NSColor(red: 0.2, green: 0.55, blue: 0.95, alpha: 1), NSColor(red: 0.04, green: 0.16, blue: 0.42, alpha: 1)])!.draw(in: globe, angle: 300)

// An orbit passing behind the satellite.
NSColor(red: 0.6, green: 0.85, blue: 1, alpha: 0.55).setStroke()
ctx.saveGState()
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: 0.5)
let orbit = NSBezierPath(ovalIn: NSRect(x: -470, y: -170, width: 940, height: 340))
orbit.lineWidth = 9
orbit.stroke()
ctx.restoreGState()

// The satellite itself, white with a soft shadow.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.5).cgColor)
satellite.draw(in: NSRect(x: 322, y: 372, width: 470, height: 470), from: .zero, operation: .sourceOver, fraction: 1)
ctx.restoreGState()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
