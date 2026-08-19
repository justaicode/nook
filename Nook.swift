// Nook - one menu-bar icon that sets the gap between menu-bar icons. Nothing else.
//
// macOS reads two hidden global defaults (NSStatusItemSpacing, NSStatusItemSelectionPadding). Apple's own
// icons pick a change up when Control Centre restarts; third-party icons only when their app restarts,
// so the menu also offers "Relaunch icon apps" (the same thing a log-out does).
// Needs Accessibility once, to find which apps own menu-bar icons.

import AppKit
import ServiceManagement

enum Shell {
    @discardableResult static func run(_ args: String...) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        try? p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    static let choices: [Int] = [0, 2, 4, 6, 8, 10, 12, 16]

    var gap: Int? {   // nil = not set = system default
        Int(Shell.run("/usr/bin/defaults", "-currentHost", "read", "-globalDomain", "NSStatusItemSpacing").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func applicationDidFinishLaunching(_: Notification) {
        // A new status item lands at the far LEFT of the cluster - under the notch on a full bar. Ask for a spot near Wi-Fi.
        item.autosaveName = "nook"
        item.button?.image = NSImage(systemSymbolName: "arrow.left.and.right.text.vertical", accessibilityDescription: "Nook")
            ?? NSImage(systemSymbolName: "arrow.left.and.line.vertical.and.arrow.right", accessibilityDescription: "Nook")
        item.menu = NSMenu(); item.menu?.delegate = self
        try? FileManager.default.createDirectory(at: App.spacerDir, withIntermediateDirectories: true)
        showSpacers = showSpacers      // writes the flag file for helpers
        spacerTick()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.spacerTick() } }
        // Seed a spot near Wi-Fi; a brand-new item otherwise lands leftmost, under the notch.
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position nook") == nil { UserDefaults.standard.set(300, forKey: "NSStatusItem Preferred Position nook") }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            parkedCheck()
            Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in Task { @MainActor in self?.parkedCheck() } }
            let line = "[\(Date())] nook visible=\(item.isVisible) frame=\(item.button?.window?.frame ?? .zero) spacers=\(spacerBundles.count)\n"
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Nook.log")
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile() } else { try? line.write(to: url, atomically: true, encoding: .utf8) }
        }
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }

    @objc func pick(_ m: NSMenuItem) {
        let v = m.tag   // -1 = system
        for k in ["NSStatusItemSpacing", "NSStatusItemSelectionPadding"] {
            if v < 0 { Shell.run("/usr/bin/defaults", "-currentHost", "delete", "-globalDomain", k) }
            else { Shell.run("/usr/bin/defaults", "-currentHost", "write", "-globalDomain", k, "-int", String(v)) }
        }
        Shell.run("/usr/bin/killall", "ControlCenter")     // Apple's icons re-read it now
    }

    // Background utilities (no Dock icon) that own a menu-bar icon, via Accessibility. Regular apps - the ones with
    // your work in them - are never touched; Apple's agents neither.
    func iconApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != getpid(), app.activationPolicy != .regular,
                  !(app.bundleIdentifier ?? "").hasPrefix("com.apple.") else { return false }
            let el = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(el, 0.2)
            var bar: AnyObject?, kids: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let b = bar,
                  AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success else { return false }
            return !((kids as? [AXUIElement]) ?? []).isEmpty
        }
    }

    // MARK: spacers - each one is its own tiny app (see NookSpacer.swift), stamped into Application Support.
    static let spacerDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Nook")
    var spacerBundles: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: App.spacerDir, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.pathExtension == "app" }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) < ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }
    func spacerWidth(_ url: URL) -> Int { (NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))?["NookWidth"] as? Int) ?? 0 }
    func spacerBundleID(_ url: URL) -> String { "com.justaicode.nook.spacer." + url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Spacer-", with: "") }
    var showSpacers: Bool { get { UserDefaults.standard.object(forKey: "showSpacers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showSpacers")
              let flag = App.spacerDir.appendingPathComponent("show")      // helpers read this at launch
              if newValue { try? "1".write(to: flag, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(at: flag) }
              DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.justaicode.nook.spacers"), object: newValue ? "1" : "0", userInfo: nil, deliverImmediately: true) } }
    @objc func addSpacer(_ m: NSMenuItem) {
        let id = UUID().uuidString.lowercased().prefix(8)
        let bundle = App.spacerDir.appendingPathComponent("Spacer-\(id).app")
        let macos = bundle.appendingPathComponent("Contents/MacOS")
        try? FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(at: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/NookSpacer"), to: macos.appendingPathComponent("NookSpacer"))
        let plist: [String: Any] = ["CFBundleIdentifier": "com.justaicode.nook.spacer.\(id)", "CFBundleExecutable": "NookSpacer", "CFBundleName": "Nook spacer",
                                    "CFBundlePackageType": "APPL", "LSUIElement": true, "NookWidth": m.tag]
        (plist as NSDictionary).write(to: bundle.appendingPathComponent("Contents/Info.plist"), atomically: true)
        Shell.run("/usr/bin/codesign", "-fs", "-", bundle.path)
        launchSpacer(bundle)
    }
    func launchSpacer(_ url: URL) {
        let c = NSWorkspace.OpenConfiguration(); c.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: c) { _, _ in }
    }
    @objc func removeSpacer(_ m: NSMenuItem) {
        let url = spacerBundles[m.tag]
        NSRunningApplication.runningApplications(withBundleIdentifier: spacerBundleID(url)).forEach { $0.terminate() }
        try? FileManager.default.removeItem(at: url)
    }
    // Every 3 s: a spacer that was dragged out left a "removed" note => forget it; one that is not running => start it.
    func spacerTick() {
        for url in spacerBundles {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("removed").path) { try? FileManager.default.removeItem(at: url); continue }
            if NSRunningApplication.runningApplications(withBundleIdentifier: spacerBundleID(url)).isEmpty { launchSpacer(url) }
        }
    }
    @objc func toggleShowSpacers() { showSpacers.toggle() }

    // macOS 26 hides an app's icons system-wide when one is dragged down out of the bar; the window then sits at y < 0.
    // Nothing in a plist to flip, so tell him where the switch is. Once per occurrence.
    var warned = false
    func parkedCheck() {
        let parked = (item.button?.window?.frame.minY ?? 0) < 0
        if !parked { warned = false; return }
        if warned { return }
        warned = true
        let a = NSAlert()
        a.messageText = "Nook's icon is hidden by macOS"
        a.informativeText = "macOS hides an app's icons when one of them is dragged down out of the menu bar. Turn Nook back on under System Settings → Menu Bar."
        a.addButton(withTitle: "Open System Settings"); a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!)
        }
    }
    @objc func quit() {
        for url in spacerBundles { NSRunningApplication.runningApplications(withBundleIdentifier: spacerBundleID(url)).forEach { $0.terminate() } }
        NSApp.terminate(nil)
    }
    @objc func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    // Apple's icons: `defaults -currentHost write com.apple.controlcenter <Key> -int 2|8` + restart Control Centre.
    // Shown = a Control Centre window with that name exists (needs Screen Recording; granted).
    static let appleKeys = [("WiFi", "Wi‑Fi"), ("Bluetooth", "Bluetooth"), ("Battery", "Battery"), ("Sound", "Sound"),
                            ("NowPlaying", "Now Playing"), ("ScreenMirroring", "Screen Mirroring"), ("Display", "Display"),
                            ("FocusModes", "Focus"), ("UserSwitcher", "Fast User Switching"), ("AirDrop", "AirDrop"),
                            ("KeyboardBrightness", "Keyboard Brightness"), ("Hearing", "Hearing"),
                            ("AccessibilityShortcuts", "Accessibility Shortcuts"), ("StageManager", "Stage Manager"), ("Weather", "Weather")]
    func shownAppleNames() -> Set<String> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return Set(list.compactMap { w in
            (w[kCGWindowLayer as String] as? Int) == 25 && (w[kCGWindowOwnerName as String] as? String)?.hasPrefix("Control Cent") == true
                ? w[kCGWindowName as String] as? String : nil
        })
    }
    @objc func toggleApple(_ m: NSMenuItem) {
        let key = App.appleKeys[m.tag].0
        Shell.run("/usr/bin/defaults", "-currentHost", "write", "com.apple.controlcenter", key, "-int", m.state == .on ? "8" : "2")
        Shell.run("/usr/bin/killall", "ControlCenter")
    }

    @objc func relaunchOne(_ m: NSMenuItem) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(m.tag)) else { return }
        relaunch([app])
    }
    @objc func relaunchAll() { relaunch(iconApps()) }
    func relaunch(_ apps: [NSRunningApplication]) {
        Task { @MainActor in
            for app in apps {
                guard let url = app.bundleURL, let bid = app.bundleIdentifier else { continue }
                // Login items live under launchd (label == bundle id). Restart them THROUGH launchd, or we end up with
                // two copies and double icons (iStat Menus Status, 19 Aug).
                let job = "gui/\(getuid())/\(bid)"
                if Shell.run("/bin/launchctl", "print", job).contains("state = running") {
                    Shell.run("/bin/launchctl", "kickstart", "-k", job); continue
                }
                app.terminate()
                for _ in 0..<20 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
                if !app.isTerminated { app.forceTerminate() }
                // Login-item helpers (iStat Menus Status...) are brought back by launchd on their own; opening them
                // ourselves too gives two copies and double icons. Wait 5 s, reopen only if nothing came back.
                for _ in 0..<20 where NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
                if NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty {
                    let c = NSWorkspace.OpenConfiguration(); c.activates = false
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: c)
                }
            }
        }
    }
    @objc func relaunchKeyboard() { Shell.run("/usr/bin/killall", "TextInputMenuAgent") }   // the "A"; launchd brings it back
}

extension App: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let cur = gap
        menu.addItem(withTitle: "Gap between icons", action: nil, keyEquivalent: "")
        for v in App.choices {
            let m = NSMenuItem(title: "\(v) pt", action: #selector(pick(_:)), keyEquivalent: ""); m.target = self; m.tag = v
            m.state = cur == v ? .on : .off; menu.addItem(m)
        }
        let sys = NSMenuItem(title: "System default", action: #selector(pick(_:)), keyEquivalent: ""); sys.target = self; sys.tag = -1
        sys.state = cur == nil ? .on : .off; menu.addItem(sys)
        menu.addItem(.separator())
        // Third-party icons only pick the gap up when their app restarts. Menu-bar utilities only, one at a time or all.
        let rs = NSMenu()
        for app in iconApps().sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            let a = NSMenuItem(title: app.localizedName ?? "?", action: #selector(relaunchOne(_:)), keyEquivalent: ""); a.target = self
            a.tag = Int(app.processIdentifier); a.image = app.icon; a.image?.size = NSSize(width: 16, height: 16); rs.addItem(a)
        }
        rs.addItem(withTitle: "Keyboard input menu (A)", action: #selector(relaunchKeyboard), keyEquivalent: "").target = self
        rs.addItem(.separator())
        rs.addItem(withTitle: "All of the above", action: #selector(relaunchAll), keyEquivalent: "").target = self
        let r = NSMenuItem(title: "Relaunch a menu-bar utility", action: nil, keyEquivalent: ""); r.submenu = rs; menu.addItem(r)
        menu.addItem(.separator())
        let ss = NSMenu()
        for w in [1, 2, 4, 8, 16, 24, 40] { let a = NSMenuItem(title: "Add \(w) pt spacer", action: #selector(addSpacer(_:)), keyEquivalent: ""); a.target = self; a.tag = w; ss.addItem(a) }
        let bundles = spacerBundles
        if !bundles.isEmpty {
            ss.addItem(.separator())
            for (i, u) in bundles.enumerated() { let a = NSMenuItem(title: "Remove spacer \(i + 1) (\(spacerWidth(u)) pt)", action: #selector(removeSpacer(_:)), keyEquivalent: ""); a.target = self; a.tag = i; ss.addItem(a) }
            ss.addItem(.separator())
            let v = NSMenuItem(title: "Show spacers to drag them (untick when placed)", action: #selector(toggleShowSpacers), keyEquivalent: ""); v.target = self
            v.state = showSpacers ? .on : .off; ss.addItem(v)
        }
        let sItem = NSMenuItem(title: "Spacers", action: nil, keyEquivalent: ""); sItem.submenu = ss; menu.addItem(sItem)
        menu.addItem(.separator())
        let shown = shownAppleNames()
        let sub = NSMenu()
        for (i, (key, label)) in App.appleKeys.enumerated() {
            let a = NSMenuItem(title: label, action: #selector(toggleApple(_:)), keyEquivalent: ""); a.target = self; a.tag = i
            a.state = shown.contains(key) ? .on : .off; sub.addItem(a)
        }
        let appleItem = NSMenuItem(title: "Apple icons", action: nil, keyEquivalent: ""); appleItem.submenu = sub; menu.addItem(appleItem)
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: ""); login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(withTitle: "Quit Nook", action: #selector(quit), keyEquivalent: "q").target = self
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
