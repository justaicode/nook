// Nook - one menu-bar icon that sets the gap between menu-bar icons. Nothing else.
//
// macOS reads two hidden global defaults (NSStatusItemSpacing, NSStatusItemSelectionPadding). Apple's own
// icons pick a change up when Control Centre restarts; third-party icons only when their app restarts,
// so the menu also offers "Relaunch icon apps" (the same thing a log-out does).
// Needs Accessibility once, to find which apps own menu-bar icons.

import AppKit

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
        if UserDefaults.standard.object(forKey: "NSStatusItem Preferred Position nook") == nil { UserDefaults.standard.set(300, forKey: "NSStatusItem Preferred Position nook") }
        item.autosaveName = "nook"
        item.button?.image = NSImage(systemSymbolName: "arrow.left.and.right.square", accessibilityDescription: "Nook")
        item.menu = NSMenu(); item.menu?.delegate = self
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

    // Apps that own a menu-bar icon, via Accessibility. Apple's agents are left alone except the keyboard "A".
    func iconApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != getpid(), !(app.bundleIdentifier ?? "").hasPrefix("com.apple.") else { return false }
            let el = AXUIElementCreateApplication(app.processIdentifier); AXUIElementSetMessagingTimeout(el, 0.2)
            var bar: AnyObject?, kids: AnyObject?
            guard AXUIElementCopyAttributeValue(el, kAXExtrasMenuBarAttribute as CFString, &bar) == .success, let b = bar,
                  AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids) == .success else { return false }
            return !((kids as? [AXUIElement]) ?? []).isEmpty
        }
    }

    @objc func relaunch() {
        Task { @MainActor in
            for app in iconApps() {
                guard let url = app.bundleURL else { continue }
                app.terminate()
                for _ in 0..<20 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
                if !app.isTerminated { app.forceTerminate() }
                let c = NSWorkspace.OpenConfiguration(); c.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: c)
            }
            Shell.run("/usr/bin/killall", "TextInputMenuAgent")   // the keyboard "A"; launchd brings it back
        }
    }
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
        let r = NSMenuItem(title: "Relaunch icon apps", action: #selector(relaunch), keyEquivalent: ""); r.target = self
        r.toolTip = "Third-party icons only pick the gap up when their app restarts. Quits and reopens them."
        menu.addItem(r)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Nook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
