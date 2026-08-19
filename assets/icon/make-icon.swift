// Draws nook-1024.png: macOS squircle, menu-bar blue, the same ↔ glyph the status item uses.
// Run: swift make-icon.swift   (build.sh turns the PNG into Nook.icns)
import AppKit
let S: CGFloat = 1024, inset: CGFloat = 100            // Apple leaves ~10% transparent margin
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let rect = NSRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.72, alpha: 1),
                    NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.42, alpha: 1)])!.draw(in: path, angle: -90)
// a faint "menu bar" strip across the top
NSColor.white.withAlphaComponent(0.10).setFill()
let strip = NSBezierPath(rect: NSRect(x: inset, y: rect.maxY - 120, width: rect.width, height: 120)); path.addClip(); strip.fill()
// three small dots in the strip = icons, tight together
for i in 0..<3 { NSColor.white.withAlphaComponent(0.85).setFill(); NSBezierPath(ovalIn: NSRect(x: rect.maxX - 120 - CGFloat(i) * 54, y: rect.maxY - 80, width: 36, height: 36)).fill() }
// the glyph
let cfg = NSImage.SymbolConfiguration(pointSize: 430, weight: .medium)
if let sym = NSImage(systemSymbolName: "arrow.left.and.right.text.vertical", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let white = NSImage(size: sym.size, flipped: false) { r in sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
    white.draw(in: NSRect(x: (S - sym.size.width)/2, y: (S - sym.size.height)/2 - 50, width: sym.size.width, height: sym.size.height))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "nook-1024.png"))
print("wrote nook-1024.png")

// Tahoe: the same glyph alone, white on transparent, for the Icon Composer layer (Nook.icon/Assets/glyph.png)
let g = NSImage(size: NSSize(width: S, height: S))
g.lockFocus()
if let sym = NSImage(systemSymbolName: "arrow.left.and.right.text.vertical", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 520, weight: .medium)) {
    let white = NSImage(size: sym.size, flipped: false) { r in sym.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
    white.draw(in: NSRect(x: (S - sym.size.width)/2, y: (S - sym.size.height)/2, width: sym.size.width, height: sym.size.height))
}
g.unlockFocus()
try! FileManager.default.createDirectory(atPath: "Nook.icon/Assets", withIntermediateDirectories: true)
try! NSBitmapImageRep(data: g.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Nook.icon/Assets/glyph.png"))
print("wrote Nook.icon/Assets/glyph.png")
