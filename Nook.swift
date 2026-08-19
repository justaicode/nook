// Nook - a menu-bar divider that hides icons behind it and shows them again in a
// panel painted to the LEFT of the notch. One Swift file, no project, no dependencies.
//
//   toggle  ‹  = our right item. Left-click: show/hide the hidden ones. Right-click: menu.
//   spacer     = our left item. 10000pt wide when hiding, so everything left of it is pushed
//                past the notch and macOS drops it. 8pt when showing. Same trick as Hidden Bar.
//   panel      = borderless NSPanel at status-bar level, right-aligned to the notch, one button per
//                hidden icon showing a ScreenCaptureKit capture of that icon. Click = we briefly show
//                the real bar and post a click on the real icon.
//
// Needs Screen Recording (captures + window names) and Accessibility (posting clicks and cmd-drags).

import AppKit
import SwiftUI
import ScreenCaptureKit

// MARK: - one status-bar window, as seen by CGWindowList
// macOS 26 hosts EVERY status item in a Control Centre window named after the item's autosave name
// ("WiFi", "com.bjango.istatmenus.cpu", "Item-0"...). The owning app is found by matching x against
// each app's Accessibility "extras menu bar" children.
struct BarItem: Identifiable {
    let id: CGWindowID, name: String
    let frame: CGRect       // CG coordinates: origin top-left, so y == 0 is the menu bar
    let onScreen: Bool
    var owner = "", bundleID = "", title = ""
    var ax: AXUIElement?    // the app's own button, for AXPress when the icon is out of reach
    var key: String { "\(bundleID.isEmpty ? "cc" : bundleID)|\(name)" }
    var isApple: Bool { Bar.appleNames.contains(name) || name.hasPrefix("BentoBox") }   // hide via defaults, not drag
    var label: String {
        let base = owner.isEmpty ? name : owner
        return title.isEmpty || title == base ? base : "\(base) — \(title)"
    }
}

enum Bar {
    static let ours: Set<String> = ["nook.spacer", "nook.toggle"]
    static let appleNames: Set<String> = ["WiFi", "Bluetooth", "Battery", "Sound", "NowPlaying", "ScreenMirroring", "Display", "FocusModes",
                                          "UserSwitcher", "AirDrop", "KeyboardBrightness", "Hearing", "AccessibilityShortcuts", "StageManager",
                                          "Weather", "Clock", "Siri", "Spotlight", "MusicRecognition", "VPN", "TimeMachine"]
    static func items() -> [BarItem] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = getpid()
        var out: [BarItem] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 25,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: b as CFDictionary),
                  f.minY == 0, f.height <= 40, f.width < 2000 else { continue }
            let name = w[kCGWindowName as String] as? String ?? ""
            if ours.contains(name) { continue }
            out.append(BarItem(id: id, name: name, frame: f, onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        out.sort { $0.frame.minX < $1.frame.minX }
        let ax = axItems()
        for i in out.indices {
            let x = out[i].frame.minX
            if let m = ax.min(by: { abs($0.x - x) < abs($1.x - x) }), abs(m.x - x) < 24 {
                out[i].owner = m.app; out[i].bundleID = m.bundle; out[i].title = m.title; out[i].ax = m.el
            }
        }
        return out
    }

    // Every running app's status items via Accessibility: x position + app name + title.
    struct AXItem { let x: CGFloat, app: String, bundle: String, title: String, el: AXUIElement }
    static func axItems() -> [AXItem] {
        guard AXIsProcessTrusted() else { return [] }
        var out: [AXItem] = []
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier != getpid() {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(el, 0.2)
            var bar: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let barEl = bar else { continue }
            var kids: AnyObject?
            guard AXUIElementCopyAttributeValue(barEl as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
                  let arr = kids as? [AXUIElement] else { continue }
            for k in arr {
                var pos: AnyObject?, title: AnyObject?, desc: AnyObject?
                AXUIElementCopyAttributeValue(k, kAXPositionAttribute as CFString, &pos)
                AXUIElementCopyAttributeValue(k, kAXTitleAttribute as CFString, &title)
                AXUIElementCopyAttributeValue(k, kAXDescriptionAttribute as CFString, &desc)
                var p = CGPoint.zero
                if let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
                out.append(AXItem(x: p.x, app: app.localizedName ?? "?", bundle: app.bundleIdentifier ?? "",
                                  title: (title as? String) ?? (desc as? String) ?? "", el: k))
            }
        }
        return out
    }

    // Where the frontmost app's last menu title ends (AppKit x). The panel must not cross it.
    static func menuTitlesRightEdge() -> CGFloat {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return 0 }
        let el = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(el, 0.2)
        var mb: AnyObject?, kids: AnyObject?, pos: AnyObject?, size: AnyObject?
        guard AXUIElementCopyAttributeValue(el, kAXMenuBarAttribute as CFString, &mb) == .success, let bar = mb,
              AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement], let last = arr.last else { return 0 }
        var p = CGPoint.zero, sz = CGSize.zero
        if AXUIElementCopyAttributeValue(last, kAXPositionAttribute as CFString, &pos) == .success, let pos { AXValueGetValue(pos as! AXValue, .cgPoint, &p) }
        if AXUIElementCopyAttributeValue(last, kAXSizeAttribute as CFString, &size) == .success, let size { AXValueGetValue(size as! AXValue, .cgSize, &sz) }
        return p.x + sz.width
    }

    // The window server's "Menubar" window is off screen while a full-screen app is in front.
    static var menuBarVisible: Bool {
        guard CGPreflightScreenCaptureAccess(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return true }
        return list.contains { ($0[kCGWindowLayer as String] as? Int) == 24 && ($0[kCGWindowName as String] as? String) == "Menubar" }
    }

    private static func post(_ t: CGEventType, _ p: CGPoint, cmd: Bool) {
        let e = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: t, mouseCursorPosition: p, mouseButton: .left)!
        if cmd { e.flags = .maskCommand }
        e.post(tap: .cghidEventTap)
    }
    static func click(_ p: CGPoint) {
        post(.mouseMoved, p, cmd: false); usleep(40_000)
        post(.leftMouseDown, p, cmd: false); usleep(60_000)
        post(.leftMouseUp, p, cmd: false)
    }
    // Cmd-drag is how a human reorders status items; we do the same, then put the cursor back.
    static func cmdDrag(from a: CGPoint, to b: CGPoint) {
        let cursor = CGEvent(source: nil)?.location ?? a
        post(.mouseMoved, a, cmd: true); usleep(60_000)
        post(.leftMouseDown, a, cmd: true); usleep(120_000)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            post(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y), cmd: true); usleep(25_000)
        }
        usleep(120_000)
        post(.leftMouseUp, b, cmd: true); usleep(60_000)
        CGWarpMouseCursorPosition(cursor)
    }

    @discardableResult static func shell(_ args: String...) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - captures
enum Capture {
    static func images(for items: [BarItem]) async -> [CGWindowID: NSImage] {
        guard !items.isEmpty,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [:] }
        var out: [CGWindowID: NSImage] = [:]
        for it in items {
            guard let w = content.windows.first(where: { $0.windowID == it.id }) else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: w)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.width = Int(filter.contentRect.width * scale); cfg.height = Int(filter.contentRect.height * scale)
            cfg.showsCursor = false; cfg.captureResolution = .best
            if let cg = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                out[it.id] = NSImage(cgImage: cg, size: filter.contentRect.size)
            }
        }
        return out
    }
}

// MARK: - the panel left of the notch
final class Panel: NSPanel {
    var onClick: ((String) -> Void)?
    var onRightClick: (() -> Void)?
    var onOverflow: (() -> Void)?
    private let stack = NSStackView()
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar; isOpaque = false; backgroundColor = .clear; hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false; isReleasedWhenClosed = false; isMovable = false
        let bg = NSView(); bg.wantsLayer = true
        bg.layer?.cornerRadius = 6; bg.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        stack.orientation = .horizontal; stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                                     stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor)])
        contentView = bg
    }
    override var canBecomeKey: Bool { false }

    // Lays out the buttons and returns the panel width. Height == menu bar height, images are 1:1.
    func render(_ all: [BarItem], images: [CGWindowID: NSImage], gap: CGFloat, height: CGFloat, maxWidth: CGFloat) -> CGFloat {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.spacing = gap; stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        // Drop icons from the LEFT until the strip fits; the dropped ones become a "+N" button.
        var items = all
        func need(_ xs: [BarItem], extra: CGFloat) -> CGFloat { 8 + extra + xs.reduce(0) { $0 + (images[$1.id]?.size.width ?? 26) } + gap * CGFloat(max(0, xs.count - (extra > 0 ? 0 : 1))) }
        while !items.isEmpty && need(items, extra: items.count < all.count ? 28 : 0) > maxWidth { items.removeFirst() }
        var width: CGFloat = 8
        if items.count < all.count {
            let more = NSButton(title: "+\(all.count - items.count)", target: self, action: #selector(overflow))
            more.isBordered = false; more.font = .systemFont(ofSize: 11, weight: .medium); more.contentTintColor = .white
            more.translatesAutoresizingMaskIntoConstraints = false
            more.widthAnchor.constraint(equalToConstant: 28).isActive = true
            stack.addArrangedSubview(more); width += 28 + gap
        }
        for it in items {
            let b = NSButton(title: "", target: self, action: #selector(hit(_:)))
            b.isBordered = false; b.identifier = NSUserInterfaceItemIdentifier(it.key); b.toolTip = it.label
            if let img = images[it.id] { b.image = img; b.imageScaling = .scaleNone }
            else if let icon = NSRunningApplication.runningApplications(withBundleIdentifier: it.bundleID).first?.icon { icon.size = NSSize(width: 18, height: 18); b.image = icon; b.imageScaling = .scaleNone }
            let w = images[it.id]?.size.width ?? 26
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: w).isActive = true
            b.heightAnchor.constraint(equalToConstant: height).isActive = true
            stack.addArrangedSubview(b)
            width += w
        }
        width += gap * CGFloat(max(0, items.count - 1))
        return width
    }
    @objc private func hit(_ b: NSButton) { onClick?(b.identifier?.rawValue ?? "") }
    @objc private func overflow() { onOverflow?() }
}

// MARK: - the app
@MainActor final class App: NSObject, NSApplicationDelegate, ObservableObject {
    static let hiddenLen: CGFloat = 10000, shownLen: CGFloat = 8
    let toggle = NSStatusBar.system.statusItem(withLength: 24)     // created first => sits to the right
    let spacer = NSStatusBar.system.statusItem(withLength: hiddenLen)
    let panel = Panel()
    var settingsWin: NSWindow?

    @Published var items: [BarItem] = []        // last full listing, taken while shown
    @Published var spacerX: CGFloat = 0
    @Published var axOK = false
    @Published var screenOK = false
    @Published var gap: Double = UserDefaults.standard.object(forKey: "gap") as? Double ?? 4 {
        didSet { UserDefaults.standard.set(gap, forKey: "gap"); renderPanel() }
    }
    var placement: [String: String] = UserDefaults.standard.dictionary(forKey: "placement") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(placement, forKey: "placement") }
    }
    var hidden: [BarItem] = [], images: [CGWindowID: NSImage] = [:]
    var expanded = false, busy = false, awaitingClick = false
    var monitor: Any?, idleTimer: Timer?

    // Apple's own items: `defaults -currentHost write com.apple.controlcenter <Key> -int 2|8`, then restart Control Center.
    // ponytail: 2 = show / 8 = hide is what this Mac's plist says today; other builds used 18/24. Fix here if one refuses.
    static let appleKeys = [("WiFi", "Wi‑Fi"), ("Bluetooth", "Bluetooth"), ("Battery", "Battery"), ("Sound", "Sound"),
                            ("NowPlaying", "Now Playing"), ("ScreenMirroring", "Screen Mirroring"), ("Display", "Display"),
                            ("FocusModes", "Focus"), ("UserSwitcher", "Fast User Switching"), ("AirDrop", "AirDrop"),
                            ("KeyboardBrightness", "Keyboard Brightness"), ("Hearing", "Hearing"),
                            ("AccessibilityShortcuts", "Accessibility Shortcuts"), ("StageManager", "Stage Manager"), ("Weather", "Weather")]

    func applicationDidFinishLaunching(_: Notification) {
        toggle.autosaveName = "nook.toggle"; spacer.autosaveName = "nook.spacer"
        toggle.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Nook")
        toggle.button?.target = self; toggle.button?.action = #selector(toggleClicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        panel.onClick = { [weak self] key in self?.activate(key) }
        panel.onRightClick = { [weak self] in self?.showMenu() }
        panel.onOverflow = { [weak self] in self?.expand() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); self?.renderPanel() }
        }
        checkPermissions(prompt: true)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.renderPanel() }
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        // ponytail: captures only happen while the icons are on screen, so every 60 s the bar flashes for ~0.4 s
        // to refresh them. Drop the timer if it annoys; icons then refresh only when you interact.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        Task { try? await Task.sleep(for: .seconds(1)); await refresh() }
    }

    // Debug trail at ~/Library/Logs/Nook.log: our two frames + every bar window. Read it when the bar looks wrong.
    func dump(_ now: [BarItem]) {
        var s = "\n[\(Date())] ax=\(axOK) screen=\(screenOK) expanded=\(expanded) toggle=\(toggle.button?.window?.frame ?? .zero) spacer=\(spacer.button?.window?.frame ?? .zero)\n"
        for i in now { s += "  \(Int(i.frame.minX))+\(Int(i.frame.width)) on=\(i.onScreen) '\(i.name)' -> \(i.label) [\(i.bundleID)]\n" }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); h.closeFile() }
        else { try? s.write(to: url, atomically: true, encoding: .utf8) }
    }
    func checkPermissions(prompt: Bool) {
        axOK = prompt ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) : AXIsProcessTrusted()
        screenOK = prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
    }

    var seconds = 0, menuEdge: CGFloat = 0
    func tick() {
        seconds += 1
        panelVisibility()
        if seconds % 2 == 0, !expanded, Bar.menuTitlesRightEdge() != menuEdge { renderPanel() }   // the front app's menus changed
        if settingsWin?.isVisible == true, seconds % 2 == 0 { checkPermissions(prompt: false) }
    }

    // MARK: show / hide
    func expand() {
        guard !expanded else { return }
        expanded = true; spacer.length = App.shownLen
        toggle.button?.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Nook")
        panel.orderOut(nil)
        startWatch()
    }
    // If macOS ever puts the spacer to the RIGHT of ‹, a 10000pt spacer would push ‹ itself off screen. Then we stay open.
    var misordered: Bool { (spacer.button?.window?.frame.minX ?? 0) > (toggle.button?.window?.frame.minX ?? 0) }
    func collapse() {
        expanded = false; awaitingClick = false; spacer.length = misordered ? App.shownLen : App.hiddenLen
        toggle.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Nook")
        stopWatch(); renderPanel()
    }
    // Reads the bar while shown: full list, which side of the spacer each item is on, fresh captures of the hidden ones.
    func snapshot() async {
        let now = Bar.items()
        let sx = spacer.button?.window?.frame.minX ?? 0
        dump(now)
        items = now; spacerX = sx
        hidden = now.filter { !$0.isApple && $0.frame.maxX <= sx + 1 }
        let fresh = await Capture.images(for: hidden)
        for (k, v) in fresh { images[k] = v }
    }
    func finish() async {
        guard expanded, !busy else { return }
        busy = true; await snapshot(); collapse(); busy = false
    }
    func refresh() async {
        guard !expanded, !busy else { return }
        busy = true; expand()
        try? await Task.sleep(for: .milliseconds(400))
        await snapshot(); collapse(); busy = false
    }

    func startWatch() {
        stopWatch()
        var idle = 0
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.inBar(NSEvent.mouseLocation) else { return }
                await self.finish()
            }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                idle = self.inBar(NSEvent.mouseLocation) ? 0 : idle + 1
                if idle >= (self.awaitingClick ? 30 : 8) { await self.finish() }
            }
        }
    }
    func stopWatch() {
        if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil
        idleTimer?.invalidate(); idleTimer = nil
    }
    func inBar(_ p: NSPoint) -> Bool {
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) else { return false }
        return p.y >= s.frame.maxY - barHeight(s)
    }
    func barHeight(_ s: NSScreen) -> CGFloat {
        s.auxiliaryTopLeftArea?.height ?? max(24, s.frame.maxY - s.visibleFrame.maxY)
    }

    // MARK: panel
    func renderPanel() {
        guard let s = NSScreen.screens.first else { return }
        let h = barHeight(s)
        let right: CGFloat, top: CGFloat
        if let notch = s.auxiliaryTopLeftArea { right = notch.maxX - 8; top = notch.maxY }
        else { right = (toggle.button?.window?.frame.minX ?? s.frame.midX) - 8; top = s.frame.maxY }
        menuEdge = Bar.menuTitlesRightEdge()
        let w = panel.render(hidden, images: images, gap: gap, height: h, maxWidth: right - menuEdge - 12)
        panel.setFrame(NSRect(x: right - w, y: top - h, width: w, height: h), display: true)
        panelVisibility()
    }
    func panelVisibility() {
        let show = !hidden.isEmpty && !expanded && Bar.menuBarVisible
        if show { if !panel.isVisible { panel.orderFrontRegardless() } } else if panel.isVisible { panel.orderOut(nil) }
    }

    // A click on a panel icon: show the real bar, find the real icon, click it. The watch collapses us after
    // the user's next click anywhere below the bar (their pick in the menu), or after 30 s.
    func activate(_ key: String) {
        Task { @MainActor in
            guard !busy else { return }
            busy = true; awaitingClick = true; expand()
            try? await Task.sleep(for: .milliseconds(400))
            let now = Bar.items(); items = now
            if let it = now.first(where: { $0.key == key }) {
                if it.onScreen { Bar.click(CGPoint(x: it.frame.midX, y: it.frame.midY)) }
                else if let ax = it.ax { AXUIElementPerformAction(ax, kAXPressAction as CFString) }   // under the notch: ask the app directly
            }
            busy = false
        }
    }

    // MARK: settings actions
    func setPlacement(_ key: String, _ side: String) { placement[key] = side; apply() }
    // Cmd-drags every third-party icon whose side disagrees with `placement`, one at a time, re-reading between moves.
    func apply() {
        Task { @MainActor in
            guard !busy else { return }
            busy = true; expand()
            try? await Task.sleep(for: .milliseconds(400))
            for _ in 0..<12 {
                let now = Bar.items()
                let sx = spacer.button?.window?.frame.minX ?? 0, tx = toggle.button?.window?.frame.maxX ?? 0
                guard let it = now.first(where: { i in
                    guard !i.isApple, i.onScreen, let want = placement[i.key] else { return false }
                    return (want == "panel") != (i.frame.maxX <= sx + 1)
                }) else { break }
                let to = placement[it.key] == "panel" ? CGPoint(x: sx - 6, y: it.frame.midY) : CGPoint(x: tx + 6, y: it.frame.midY)
                Bar.cmdDrag(from: CGPoint(x: it.frame.midX, y: it.frame.midY), to: to)
                try? await Task.sleep(for: .milliseconds(500))
            }
            await snapshot(); collapse(); busy = false
        }
    }
    // Spacing of the REAL bar: two hidden global defaults macOS reads at login. 0 = system default (about 16).
    @Published var barGap: Double = {
        let v = Bar.shell("/usr/bin/defaults", "-currentHost", "read", "-globalDomain", "NSStatusItemSpacing").trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(v) ?? 0
    }() {
        didSet {
            for k in ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"] {
                if barGap == 0 { Bar.shell("/usr/bin/defaults", "-currentHost", "delete", "-globalDomain", k) }
                else { Bar.shell("/usr/bin/defaults", "-currentHost", "write", "-globalDomain", k, "-int", String(Int(barGap))) }
            }
            // Restarting Control Centre re-reads it for Apple's icons at once; third-party icons follow at their next launch / your next login.
            Bar.shell("/usr/bin/killall", "ControlCenter")
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await refresh() }
        }
    }
    func setApple(_ key: String, shown: Bool) {
        Bar.shell("/usr/bin/defaults", "-currentHost", "write", "com.apple.controlcenter", key, "-int", shown ? "2" : "8")
        Bar.shell("/usr/bin/killall", "ControlCenter")
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await refresh() }
    }

    // MARK: toggle item
    @objc func toggleClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showMenu(); return }
        if expanded { Task { await finish() } } else { expand() }
    }
    func showMenu() {
            let m = NSMenu()
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(withTitle: "Re-apply order", action: #selector(reapply), keyEquivalent: "").target = self
            m.addItem(withTitle: "Refresh panel", action: #selector(refreshNow), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            NSApp.activate(ignoringOtherApps: true)
            m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    @objc func reapply() { apply() }
    @objc func refreshNow() { Task { await refresh() } }
    @objc func openSettings() {
        if settingsWin == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(app: self)))
            w.title = "Nook"; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
            settingsWin = w
        }
        checkPermissions(prompt: false)
        NSApp.activate(ignoringOtherApps: true)
        settingsWin?.center(); settingsWin?.makeKeyAndOrderFront(nil)
        Task { await refresh() }
    }
}

// MARK: - settings window
struct SettingsView: View {
    @ObservedObject var app: App
    @State private var draft: Double = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !app.axOK { banner("Accessibility permission missing", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
            if app.misordered { Text("The gap sits right of ‹ — Cmd-drag ‹ to the right of it, then Refresh panel.").padding(8).background(Color.yellow.opacity(0.18)).cornerRadius(8).padding(.bottom, 6) }
            if !app.screenOK { banner("Screen Recording permission missing", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
            section("Third-party icons")
            ForEach(app.items.filter { !$0.isApple }) { it in
                row(it.label) {
                    Picker("", selection: Binding(get: { app.placement[it.key] ?? (it.frame.maxX <= app.spacerX + 1 ? "panel" : "bar") },
                                                  set: { app.setPlacement(it.key, $0) })) {
                        Text("Bar").tag("bar"); Text("Panel").tag("panel")
                    }.pickerStyle(.segmented).frame(width: 130)
                }
            }
            section("Apple icons")
            ForEach(App.appleKeys, id: \.0) { key, label in
                let shown = app.items.contains { $0.isApple && ($0.name == key || $0.name.hasPrefix(key + "-")) }
                row(label) {
                    Picker("", selection: Binding(get: { shown }, set: { app.setApple(key, shown: $0) })) {
                        Text("Show").tag(true); Text("Hide").tag(false)
                    }.pickerStyle(.segmented).frame(width: 130)
                }
            }
            Divider().padding(.vertical, 8)
            HStack {
                Text("Bar spacing").foregroundStyle(.secondary)
                Slider(value: $draft, in: 0...16, step: 1, onEditingChanged: { if !$0 { app.barGap = draft } }).frame(width: 140)
                Text(draft == 0 ? "system" : "\(Int(draft)) pt").frame(width: 50, alignment: .leading)
                Spacer()
                Text("Apple icons: now · others: after log out/in").font(.caption).foregroundStyle(.secondary)
            }.padding(.bottom, 6)
            HStack {
                Text("Panel gap").foregroundStyle(.secondary)
                Slider(value: $app.gap, in: 0...16, step: 1).frame(width: 140)
                Spacer()
                Button("Re-apply order") { app.apply() }
            }
        }
        .padding(16).frame(width: 440)
        .onAppear { draft = app.barGap }
    }
    func section(_ t: String) -> some View { Text(t).font(.caption).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 4) }
    func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).lineLimit(1); Spacer(); c() }.padding(.vertical, 3)
    }
    func banner(_ text: String, _ url: String) -> some View {
        HStack {
            Image(systemName: "lock"); Text(text); Spacer()
            Button("Open System Settings") { NSWorkspace.shared.open(URL(string: url)!) }
        }
        .padding(8).background(Color.yellow.opacity(0.18)).cornerRadius(8).padding(.bottom, 6)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
