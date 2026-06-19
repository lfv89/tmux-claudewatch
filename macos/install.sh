#!/bin/sh
# Optional: install the macOS menu-bar app and run it at login via a LaunchAgent.
# The tmux plugin works without any of this — run this only if you want the
# menu-bar pill + notifications.
#
# No clone or Swift toolchain needed — this downloads a prebuilt app:
#   curl -fsSL https://raw.githubusercontent.com/lfv89/tmux-claudewatch/main/macos/install.sh | sh
#
# Or, from a checkout (falls back to building from source if no release exists):
#   ~/.tmux/plugins/tmux-claudewatch/macos/install.sh
#
# Re-run after updates; it reinstalls and reloads in place.
set -eu

REPO=lfv89/tmux-claudewatch
LABEL=works.vlabs.tmuxclaudewatcher
PLIST="$LABEL.plist"
AGENTS="$HOME/Library/LaunchAgents"
# Stable home for the app, decoupled from the TPM checkout so the LaunchAgent
# path survives plugin updates/relocations.
SUPPORT="$HOME/Library/Application Support/claudewatch"
APP=ClaudeTmuxWatcher.app
BIN_REL="Contents/MacOS/ClaudeTmuxWatcher"
ASSET="$APP.zip"
URL="https://github.com/$REPO/releases/latest/download/$ASSET"

# If invoked from a checkout, $0 sits next to build.sh — enables the source fallback.
SELF_DIR=""
case "${0:-}" in
  */*) d=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || d=""
       [ -n "$d" ] && [ -f "$d/build.sh" ] && SELF_DIR="$d" ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$SUPPORT"

got=""
echo "Fetching prebuilt app from latest release ..."
if curl -fSL "$URL" -o "$tmp/$ASSET" 2>/dev/null && (cd "$tmp" && unzip -oq "$ASSET") \
   && [ -d "$tmp/$APP" ]; then
  rm -rf "$SUPPORT/$APP"
  cp -R "$tmp/$APP" "$SUPPORT/$APP"
  got="release"
fi

if [ -z "$got" ]; then
  if [ -n "$SELF_DIR" ] && command -v swiftc >/dev/null 2>&1; then
    echo "No release download; building from source ..."
    (cd "$SELF_DIR" && ./build.sh --app)
    rm -rf "$SUPPORT/$APP"
    cp -R "$SELF_DIR/$APP" "$SUPPORT/$APP"
    got="source"
  else
    echo "error: couldn't download a prebuilt app." >&2
    if [ -z "$SELF_DIR" ]; then
      echo "  Check your connection, or run from a checkout to build locally:" >&2
      echo "    ~/.tmux/plugins/tmux-claudewatch/macos/install.sh" >&2
    else
      echo "  Install the Swift toolchain to build locally: xcode-select --install" >&2
    fi
    exit 1
  fi
fi

BIN="$SUPPORT/$APP/$BIN_REL"
# A downloaded app is quarantined; we ran this installer deliberately, so clear it
# (this is the unsigned-binary Gatekeeper sidestep — no Apple Developer ID needed).
xattr -dr com.apple.quarantine "$SUPPORT/$APP" 2>/dev/null || true
chmod +x "$BIN"

# LaunchAgent with the stable absolute path baked in (launchd won't expand $HOME).
mkdir -p "$AGENTS"
cat > "$AGENTS/$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/tmuxclaudewatcher.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/tmuxclaudewatcher.log</string>
</dict>
</plist>
PLIST_EOF

# Reload cleanly if a previous version is already loaded.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl load -w "$AGENTS/$PLIST"

echo
echo "Installed ($got). Menu-bar app is running and will start at login."
echo "  uninstall:  launchctl bootout gui/$(id -u)/$LABEL ; rm \"$AGENTS/$PLIST\" ; rm -rf \"$SUPPORT\""
echo "  logs:       /tmp/tmuxclaudewatcher.log"
