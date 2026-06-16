#!/bin/sh
# Build ClaudeTmuxWatcher. Pass `--app` to also assemble a minimal .app bundle
# (handy for Login Items); the bare binary is enough for the LaunchAgent.
set -eu

cd "$(dirname "$0")"
BIN=ClaudeTmuxWatcher

echo "Compiling $BIN ..."
swiftc -O "$BIN.swift" -o "$BIN"
echo "Built ./$BIN"

if [ "${1:-}" = "--app" ]; then
  APP="$BIN.app"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS"
  cp "$BIN" "$APP/Contents/MacOS/$BIN"
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>com.vee.claudetmuxwatcher</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
  echo "Built ./$APP"
fi
