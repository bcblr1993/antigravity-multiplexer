import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 225, yRadius: 225)
NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.33, blue: 0.87, alpha: 1), ending: NSColor(calibratedRed: 0.48, green: 0.30, blue: 0.91, alpha: 1))!.draw(in: background, angle: -35)
func window(_ rect: NSRect, alpha: CGFloat) {
    NSColor.white.withAlphaComponent(alpha).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 58, yRadius: 58).fill()
    NSColor.white.withAlphaComponent(0.45).setStroke()
    let outline = NSBezierPath(roundedRect: rect, xRadius: 58, yRadius: 58)
    outline.lineWidth = 5; outline.stroke()
}
window(NSRect(x: 226, y: 365, width: 566, height: 390), alpha: 0.42)
window(NSRect(x: 175, y: 260, width: 566, height: 390), alpha: 0.65)
window(NSRect(x: 135, y: 145, width: 566, height: 390), alpha: 0.96)
NSColor(calibratedRed: 0.29, green: 0.36, blue: 0.86, alpha: 1).setFill()
for x in [213.0, 263.0, 313.0] { NSBezierPath(ovalIn: NSRect(x: x, y: 455, width: 23, height: 23)).fill() }
let line = NSBezierPath(roundedRect: NSRect(x: 211, y: 374, width: 412, height: 33), xRadius: 16, yRadius: 16)
NSColor(calibratedRed: 0.70, green: 0.74, blue: 0.95, alpha: 1).setFill(); line.fill()
let line2 = NSBezierPath(roundedRect: NSRect(x: 211, y: 310, width: 285, height: 33), xRadius: 16, yRadius: 16); line2.fill()
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
