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

# Icon: assets/icon/make-icon.swift draws the 1024 PNG (regenerable, gitignored), iconutil wants every size.
SRC=assets/icon/nook-1024.png
[ -f "$SRC" ] || (cd assets/icon && swift make-icon.swift >/dev/null)
mkdir -p "$APP/Contents/Resources" build/nook.iconset
for s in 16 32 64 128 256 512; do
  sips -z $s $s "$SRC" --out "build/nook.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$SRC" --out "build/nook.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/nook.iconset -o "$APP/Contents/Resources/Nook.icns" && rm -rf build/nook.iconset && echo "icon"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nook</string>
  <key>CFBundleIdentifier</key><string>com.justaicode.nook</string>
  <key>CFBundleExecutable</key><string>Nook</string>
  <key>CFBundleIconFile</key><string>Nook</string>
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
