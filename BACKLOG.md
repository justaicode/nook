# Nook — backlog / handoff (2026-08-20)

## RESUME HERE
**v0.1 is notarized and shipped-ready (20 Aug 2026): `build/Nook.zip`**, Gatekeeper-verified
("accepted · Notarized Developer ID"). **DECIDED 20 Aug: distribute via GitHub release.**
SHIPPED: public repo `justaicode/nook`, tag v0.1, zip attached —
https://github.com/justaicode/nook/releases/tag/v0.1 (21 Aug 2026). Future releases: bump
version, `./build.sh --release` (needs a full notarization round), tag, `gh release create`. /Applications still on the Development identity on purpose (TCC
grants survive).

Developer ID cert: SOLVED 20 Aug. Xcode's menu never offered it; the portal did — CSR generated
with openssl (no Keychain Assistant needed), he logged in, the rest was driven in Chrome:
Certificates → + → Developer ID Application → G2 Sub-CA → upload CSR. The cert was then pulled
via the ASC API (GET /v1/certificates includes certificateContent; type is
DEVELOPER_ID_APPLICATION_G2) and imported next to the openssl key with `security import`.
Creating via the API directly is impossible — POST /v1/certificates returns 403 "Account Holder
only" for Developer ID, for every key role. Identity: "Developer ID Application: Roberto Zanon
(85LHNZC32T)", expires 2031-08-21, login keychain.

Notarization gotchas (first submission took ~3 h in "In Progress" — normal for a brand-new
Developer ID account): `notarytool --wait` died on a NSURLErrorDomain -1001 poll timeout after
~1 h and build.sh's `| tail` masked the failure as exit 0 — staple+zip silently didn't run.
If it happens again: `xcrun notarytool info <id>` and, once Accepted, staple+zip by hand
(build.sh lines 65-66). Consider `set -o pipefail` in build.sh.

Nook = one menu-bar icon → menu: gap between icons (0–16 pt, System), Apple icons show/hide,
relaunch a menu-bar utility (so third-party icons pick the gap up), spacers, start at login, quit.
Files: `Nook.swift` (app), `NookSpacer.swift` (one spacer = one helper app), `build.sh`, `assets/icon/`.
Build + install: `./build.sh --run`. Signed with the Apple Development identity so TCC grants survive.

## Open
- ~~App icon pale/zoomed in System Settings → Menu Bar~~ SOLVED 2026-08-20, see below.
- **App icon shows as the pale placeholder in System Settings → Menu Bar** even though `NSWorkspace`
  resolves it fine (Finder/Dock OK). Tried: icns, LaunchServices re-register, icon cache flush, Tahoe
  Assets.car from `assets/icon/Nook.icon` via actool (absolute paths!), CFBundleIconName. Still pale.
  2026-08-20: FIXED pale by renaming everything to "AppIcon" (package, --app-icon, CFBundleIconName/File).
  Glyph size: the ONLY knob that works is the symbol pointSize in make-icon.swift (now 300 ≈ 55% of the
  squircle); icon.json layer "scale" is ignored by the renderer. Opaque corner dots pin the layer's
  content bounds to the canvas (squircle mask hides them). Render scales ~linearly with pointSize.
  To verify a build without trusting caches: copy the .app under a throwaway bundle id, lsregister -f,
  render NSWorkspace.shared.icon (scratch scripts iconcheck2/measure.swift). CFBundleVersion now 5.
  The Settings pane kept showing its own stale copy even after all that — the fix was flushing the
  user icon caches: rm -rf "$(getconf DARWIN_USER_CACHE_DIR)/com.apple.iconservices"{,agent} and
  ~/Library/Caches/com.apple.systemsettings.menucache, then killall iconservicesagent ControlCenter
  "System Settings". lsregister/version bumps alone never refreshed the pane.
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
