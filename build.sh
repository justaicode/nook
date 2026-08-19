#!/bin/bash
# Build Nook.app and put it in /Applications.
#   build.sh          build + install
#   build.sh --run    also launch
#   build.sh --here   build into build/ only
#
# One Swift file, no project. Signed with the Apple Development identity (NOT ad-hoc) so the
# Screen Recording + Accessibility grants survive rebuilds - TCC keys off the signing identity,
# and an ad-hoc signature changes with every build.
# The install REPLACES the bundle (rm -rf + ditto): cp over a running .app kills it in dyld.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Nook.app"
IDENTITY="Apple Development: Roberto Zanon (5P2HM5SHVL)"

rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/Nook" Nook.swift
swiftc -O -target arm64-apple-macosx14.0 -framework AppKit -o "$APP/Contents/MacOS/NookSpacer" NookSpacer.swift
echo "built $(du -h "$APP/Contents/MacOS/Nook" | cut -f1) + spacer helper"

# Icon: assets/icon/make-icon.swift draws the glyph PNG (regenerable, gitignored); assets/icon/Nook.icon is the
# Icon Composer package (tracked); actool (Xcode 26) compiles it to Assets.car + a legacy icns. Tahoe's Settings
# panes only show icons that come from Assets.car - a plain .icns stays the pale placeholder there.
[ -f assets/icon/Nook.icon/Assets/glyph.png ] || (cd assets/icon && swift make-icon.swift >/dev/null)
mkdir -p "$APP/Contents/Resources"
xcrun actool assets/icon/Nook.icon --compile "$APP/Contents/Resources" --app-icon Nook --include-all-app-icons \
  --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist build/icon.plist >/dev/null 2>&1 && echo "icon"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nook</string>
  <key>CFBundleIdentifier</key><string>com.justaicode.nook</string>
  <key>CFBundleExecutable</key><string>Nook</string>
  <key>CFBundleIconFile</key><string>Nook</string>
  <key>CFBundleIconName</key><string>Nook</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null && echo "signed ($IDENTITY)" \
  || { codesign --force --deep --sign - "$APP"; echo "signed ad-hoc (permissions will NOT survive rebuilds)"; }

[ "${1:-}" = "--here" ] && { echo "left at $APP"; exit 0; }

DEST="/Applications/Nook.app"
if pgrep -x Nook >/dev/null; then pkill -x Nook; sleep 0.5; echo "quit the running copy"; fi
rm -rf "$DEST"; ditto "$APP" "$DEST"; echo "installed $DEST"
[ "${1:-}" = "--run" ] && { open "$DEST"; echo "launched"; } || true
