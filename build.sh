#!/bin/bash
# Build Nook.app and put it in /Applications.
#   build.sh            build + install
#   build.sh --run      also launch
#   build.sh --here     build into build/ only
#   build.sh --release  Developer ID + notarize + staple → build/Nook.zip (no install)
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

# Icon: assets/icon/make-icon.swift draws the glyph PNG (regenerable, gitignored); assets/icon/AppIcon.icon is the
# Icon Composer package (tracked); actool (ABSOLUTE paths only, it crashes on relative ones) (Xcode 26) compiles it to Assets.car + a legacy icns. Tahoe's Settings
# panes only show icons that come from Assets.car - a plain .icns stays the pale placeholder there.
[ -f assets/icon/AppIcon.icon/Assets/glyph.png ] || (cd assets/icon && swift make-icon.swift >/dev/null)
mkdir -p "$APP/Contents/Resources"
xcrun actool "$PWD/assets/icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --app-icon AppIcon --include-all-app-icons \
  --platform macosx --minimum-deployment-target 26.0 --output-partial-info-plist "$PWD/build/icon.plist" >/dev/null 2>&1 && echo "icon"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nook</string>
  <key>CFBundleIdentifier</key><string>com.justaicode.nook</string>
  <key>CFBundleExecutable</key><string>Nook</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# build.sh --release: Developer ID + notarize + staple → build/Nook.zip for direct download.
# Does NOT install: /Applications stays on the Development identity so the TCC grants survive.
# Reuses the ASC API key already used for App Store uploads (~/.appstoreconnect/private_keys).
if [ "${1:-}" = "--release" ]; then
  DEVID=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"' || true)
  [ -n "$DEVID" ] || { echo "No Developer ID Application certificate. Create it once:"
    echo "Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates… → + → Developer ID Application"; exit 1; }
  KEY=KZA2V6P98G ISSUER=ff1832a9-2c1c-400d-9844-8f1c3b5f8d42
  codesign --force --options runtime --timestamp --sign "$DEVID" "$APP/Contents/MacOS/NookSpacer"
  codesign --force --options runtime --timestamp --sign "$DEVID" "$APP"
  ditto -c -k --keepParent "$APP" build/Nook-notarize.zip
  xcrun notarytool submit build/Nook-notarize.zip --key ~/.appstoreconnect/private_keys/AuthKey_$KEY.p8 \
    --key-id $KEY --issuer $ISSUER --wait
  xcrun stapler staple "$APP"
  rm build/Nook-notarize.zip; ditto -c -k --keepParent "$APP" build/Nook.zip
  echo "notarized + stapled → build/Nook.zip"; exit 0
fi

codesign --force --deep --sign "$IDENTITY" "$APP" 2>/dev/null && echo "signed ($IDENTITY)" \
  || { codesign --force --deep --sign - "$APP"; echo "signed ad-hoc (permissions will NOT survive rebuilds)"; }

[ "${1:-}" = "--here" ] && { echo "left at $APP"; exit 0; }

DEST="/Applications/Nook.app"
if pgrep -x Nook >/dev/null; then pkill -x Nook; sleep 0.5; echo "quit the running copy"; fi
rm -rf "$DEST"; ditto "$APP" "$DEST"; echo "installed $DEST"
# Existing spacer helpers carry their own copy of NookSpacer: refresh them, Nook relaunches them within 3 s.
for b in ~/Library/Application\ Support/Nook/Spacer-*.app; do
  [ -d "$b" ] || continue
  cp "$DEST/Contents/MacOS/NookSpacer" "$b/Contents/MacOS/NookSpacer"; codesign -fs - "$b" 2>/dev/null; pkill -f "$b" || true
done
[ "${1:-}" = "--run" ] && { open "$DEST"; echo "launched"; } || true
