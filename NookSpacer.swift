// NookSpacer - one transparent menu-bar gap, as its OWN app, so that dragging it out of the bar (which on
// macOS 26 hides the whole app) takes only this spacer with it and leaves Nook alone.
// Nook stamps a copy of this into ~/Library/Application Support/Nook/Spacer-<id>.app with its own bundle id
// and a NookWidth key. Nook toggles the grab-handle via a distributed notification.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let width = CGFloat((Bundle.main.infoDictionary?["NookWidth"] as? Int) ?? 8)
var show = FileManager.default.fileExists(atPath: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("show").path)
let prefs = UserDefaults.standard
if prefs.object(forKey: "NSStatusItem Preferred Position spacer") == nil { prefs.set(300, forKey: "NSStatusItem Preferred Position spacer") }
let item = NSStatusBar.system.statusItem(withLength: width)
item.autosaveName = "spacer"

func dress() {
    let handle = max(width, 14)
    item.length = show ? handle : width
    item.button?.image = show ? NSImage(size: NSSize(width: handle - 2, height: 16), flipped: false) { r in
        NSColor.white.withAlphaComponent(0.35).setFill(); NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill(); return true } : nil
    item.button?.image?.isTemplate = false
    item.button?.alphaValue = show ? 1 : 0
}
dress()
DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.justaicode.nook.spacers"), object: nil, queue: .main) { n in
    show = (n.object as? String) == "1"; dress()
}
// Dragged out of the bar => macOS parks the window below the screen. Leave a note for Nook and quit.
var parkedTicks = 0
Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
    parkedTicks = (item.button?.window?.frame.minY ?? 0) < 0 ? parkedTicks + 1 : 0
    if parkedTicks >= 3 {
        try? "removed".write(to: Bundle.main.bundleURL.appendingPathComponent("removed"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
app.run()
