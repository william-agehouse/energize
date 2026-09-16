#!/bin/bash
# Builds "Energize.app" into build/. Re-run after editing src/main.swift.
set -euo pipefail
cd "$(dirname "$0")"

# Everything below comes from Apple's command line developer tools. They are a
# free download but not installed by default, and the errors you get without them
# are cryptic, so say so plainly first.
MISSING=""
for tool in swift swiftc lipo iconutil codesign; do
  command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
  echo "Missing:$MISSING" >&2
  echo >&2
  echo "These come with Apple's command line developer tools. Install them with:" >&2
  echo >&2
  echo "    xcode-select --install" >&2
  echo >&2
  echo "then run this script again. Nothing was built." >&2
  exit 1
fi

APP="build/Energize.app"
# Where an installed copy lives. Overridable so the install path can be tested
# without touching the real one.
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALLED="$INSTALL_DIR/Energize.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Energize</string>
  <key>CFBundleDisplayName</key>       <string>Energize</string>
  <key>CFBundleExecutable</key>        <string>Energize</string>
  <key>CFBundleIdentifier</key>        <string>bio.ferreiraandren.energize</string>
  <key>CFBundleVersion</key>           <string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <key>CFBundleIconFile</key>          <string>AppIcon</string>
  <!-- Menu bar only: no Dock icon, no app switcher entry. -->
  <key>LSUIElement</key>               <true/>
</dict>
</plist>
PLIST

# The icon is drawn from the same bolt glyph the menu bar uses.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift tools/makeicon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Build for both processor families so the app runs on Intel MacBooks as well as
# Apple Silicon ones. swiftc handles one architecture at a time, so compile twice
# and join the results.
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 \
    -target "$arch-apple-macos13.0" \
    -framework AppKit \
    -o "build/Energize-$arch" \
    src/main.swift
done
lipo -create -output "$APP/Contents/MacOS/Energize" build/Energize-arm64 build/Energize-x86_64
rm -f build/Energize-arm64 build/Energize-x86_64

# Ad-hoc signature so macOS treats it as a stable identity across rebuilds.
# Ship the optional grant script inside the bundle, so someone who installs the
# app can find it without cloning the repo.
cp grant.sh "$APP/Contents/Resources/grant.sh"
chmod 755 "$APP/Contents/Resources/grant.sh"

codesign --force --sign - "$APP"

echo "Built: $APP"

# A freshly compiled app carries no quarantine flag, so it just opens. Strip one
# anyway in case the source arrived as a downloaded zip, which marks every file
# it unpacks.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Keep an installed copy in step with the build, so a rebuild doesn't leave a
# stale app in /Applications behind the one in build/.
if [ -d "$INSTALLED" ]; then
  # Put it back afterwards if it was running, rather than leaving the menu bar
  # empty and the user wondering where it went.
  WAS_RUNNING=no
  pgrep -f "$INSTALLED" >/dev/null && WAS_RUNNING=yes
  pkill -f "$INSTALLED" 2>/dev/null || true
  rm -rf "$INSTALLED"
  cp -R "$APP" "$INSTALLED"
  echo "Refreshed: $INSTALLED"
  if [ "$WAS_RUNNING" = yes ]; then
    sleep 1
    open "$INSTALLED"
    echo "Restarted it."
  fi
else
  # First time on this Mac. Do not move it there without being asked; just say
  # how, because a menu bar app that appears out of nowhere is unsettling.
  echo
  echo "To install it:"
  echo "    cp -R $PWD/$APP $INSTALL_DIR/"
  echo "    open $INSTALLED"
  echo
  echo "It has no window and no Dock icon. Look for the bolt in the menu bar."
fi
