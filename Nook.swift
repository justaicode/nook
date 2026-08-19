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
struct BarItem: Identifiable {
    let id: CGWindowID, pid: pid_t, owner: String, bundleID: String?, name: String
    let frame: CGRect       // CG coordinates: origin top-left, so y == 0 is the menu bar
    let onScreen: Bool
    var key: String { "\(bundleID ?? owner)|\(name)" }
    var isCC: Bool { bundleID == "com.apple.controlcenter" }   // Apple's cluster: hide via defaults, not drag
    var label: String { name.isEmpty || name.hasPrefix("Item-") ? owner : "\(owner) — \(name)" }
}

enum Bar {
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
            let app = NSRunningApplication(processIdentifier: pid)
            out.append(BarItem(id: id, pid: pid,
                               owner: w[kCGWindowOwnerName as String] as? String ?? app?.localizedName ?? "?",
                               bundleID: app?.bundleIdentifier,
                               name: w[kCGWindowName as String] as? String ?? "",
                               frame: f, onScreen: w[kCGWindowIsOnscreen as String] as? Bool ?? false))
        }
        return out.sorted { $0.frame.minX < $1.frame.minX }
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
    private let stack = NSStackView()
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
    func render(_ items: [BarItem], images: [CGWindowID: NSImage], gap: CGFloat, height: CGFloat) -> CGFloat {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.spacing = gap; stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
        var width: CGFloat = 8
        for it in items {
            let b = NSButton(title: "", target: self, action: #selector(hit(_:)))
            b.isBordered = false; b.identifier = NSUserInterfaceItemIdentifier(it.key); b.toolTip = it.label
            if let img = images[it.id] { b.image = img; b.imageScaling = .scaleNone }
            else if let icon = NSRunningApplication(processIdentifier: it.pid)?.icon { icon.size = NSSize(width: 18, height: 18); b.image = icon; b.imageScaling = .scaleNone }
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

    func checkPermissions(prompt: Bool) {
        axOK = prompt ? AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) : AXIsProcessTrusted()
        screenOK = prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
    }

    var seconds = 0
    func tick() {
        seconds += 1
        panelVisibility()
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
        items = now; spacerX = sx
        hidden = now.filter { !$0.isCC && $0.onScreen && $0.frame.maxX <= sx + 1 }
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
        let w = panel.render(hidden, images: images, gap: gap, height: h)
        let right: CGFloat, top: CGFloat
        if let notch = s.auxiliaryTopLeftArea { right = notch.maxX - 8; top = notch.maxY }
        else { right = (toggle.button?.window?.frame.minX ?? s.frame.midX) - 8; top = s.frame.maxY }
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
            if let it = now.first(where: { $0.key == key && $0.onScreen }) { Bar.click(CGPoint(x: it.frame.midX, y: it.frame.midY)) }
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
                    guard !i.isCC, i.onScreen, let want = placement[i.key] else { return false }
                    return (want == "panel") != (i.frame.maxX <= sx + 1)
                }) else { break }
                let to = placement[it.key] == "panel" ? CGPoint(x: sx - 6, y: it.frame.midY) : CGPoint(x: tx + 6, y: it.frame.midY)
                Bar.cmdDrag(from: CGPoint(x: it.frame.midX, y: it.frame.midY), to: to)
                try? await Task.sleep(for: .milliseconds(500))
            }
            await snapshot(); collapse(); busy = false
        }
    }
    func setApple(_ key: String, shown: Bool) {
        Bar.shell("/usr/bin/defaults", "-currentHost", "write", "com.apple.controlcenter", key, "-int", shown ? "2" : "8")
        Bar.shell("/usr/bin/killall", "ControlCenter")
        Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await refresh() }
    }

    // MARK: toggle item
    @objc func toggleClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(withTitle: "Re-apply order", action: #selector(reapply), keyEquivalent: "").target = self
            m.addItem(withTitle: "Refresh panel", action: #selector(refreshNow), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            toggle.menu = m; toggle.button?.performClick(nil); toggle.menu = nil
            return
        }
        if expanded { Task { await finish() } } else { expand() }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !app.axOK { banner("Accessibility permission missing", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
            if app.misordered { Text("The gap sits right of ‹ — Cmd-drag ‹ to the right of it, then Refresh panel.").padding(8).background(Color.yellow.opacity(0.18)).cornerRadius(8).padding(.bottom, 6) }
            if !app.screenOK { banner("Screen Recording permission missing", "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") }
            section("Third-party icons")
            ForEach(app.items.filter { !$0.isCC }) { it in
                row(it.label) {
                    Picker("", selection: Binding(get: { app.placement[it.key] ?? (it.frame.maxX <= app.spacerX + 1 ? "panel" : "bar") },
                                                  set: { app.setPlacement(it.key, $0) })) {
                        Text("Bar").tag("bar"); Text("Panel").tag("panel")
                    }.pickerStyle(.segmented).frame(width: 130)
                }
            }
            section("Apple icons")
            ForEach(App.appleKeys, id: \.0) { key, label in
                let shown = app.items.contains { $0.isCC && ($0.name == key || $0.name.hasPrefix(key + "-")) }
                row(label) {
                    Picker("", selection: Binding(get: { shown }, set: { app.setApple(key, shown: $0) })) {
                        Text("Show").tag(true); Text("Hide").tag(false)
                    }.pickerStyle(.segmented).frame(width: 130)
                }
            }
            Divider().padding(.vertical, 8)
            HStack {
                Text("Panel gap").foregroundStyle(.secondary)
                Slider(value: $app.gap, in: 0...16, step: 1).frame(width: 140)
                Spacer()
                Button("Re-apply order") { app.apply() }
            }
        }
        .padding(16).frame(width: 440)
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
