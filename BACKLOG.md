# Nook — backlog / handoff (2026-08-19)

Nook = one menu-bar icon → menu: gap between icons (0–16 pt, System), Apple icons show/hide,
relaunch a menu-bar utility (so third-party icons pick the gap up), spacers, start at login, quit.
Files: `Nook.swift` (app), `NookSpacer.swift` (one spacer = one helper app), `build.sh`, `assets/icon/`.
Build + install: `./build.sh --run`. Signed with the Apple Development identity so TCC grants survive.

## Open
- **App icon shows as the pale placeholder in System Settings → Menu Bar** even though `NSWorkspace`
  resolves it fine (Finder/Dock OK). Tried: icns, LaunchServices re-register, icon cache flush, Tahoe
  Assets.car from `assets/icon/Nook.icon` via actool (absolute paths!), CFBundleIconName. Still pale.
  Untested ideas: the pane might key off a record created before the icon existed (try a new bundle id
  once, e.g. com.justaicode.nook2 — costs one re-grant of Accessibility + Screen Recording); or it wants
  the icon layer named "AppIcon"; or log out/in.
- Nook's icon lives at the far left of the cluster when he drags it there → covered by long app menus.
  Keep it near Wi-Fi (seeded Preferred Position 300 on first launch only).
- `defaults … com.apple.controlcenter <Key> -int 2|8` for Apple icons: 2/8 read off his plist; keys not
  yet toggled by him are unverified (some builds used 18/24).

## Facts that cost hours (macOS 26)
- Every status item is a Control Centre window named by its autosaveName; owner app only via AX.
- Dragging an item DOWN out of the bar hides THAT APP's icons system-wide; the only switch is
  System Settings → Menu Bar; no plist. Hence spacers as separate helper apps (own bundle ids).
- New items land leftmost (under the notch on a full bar) → seed `NSStatusItem Preferred Position`.
- Spacing defaults apply to Apple icons on `killall ControlCenter`; third-party only when the owning
  app relaunches; login-item helpers must be restarted via `launchctl kickstart -k` or you get doubles.
- `NSStatusItem.length = 10000` is clamped to ~5016 but still pushes everything left of it off.
- The divider/notch-panel version (Ice-style) exists in git history before "Nook = just the gap setter".
