#!/bin/sh
# Optional: build the macOS menu-bar app and run it at login via a LaunchAgent.
# The tmux plugin works without any of this — run this only if you want the menu-bar pill.
#
#   ~/.tmux/plugins/tmux-claudewatch/macos/install.sh
#
# Re-run after pulling updates; it rebuilds and reloads in place.
set -eu

cd "$(dirname "$0")"
LABEL=works.vlabs.tmuxclaudewatcher
PLIST="$LABEL.plist"
AGENTS="$HOME/Library/LaunchAgents"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "error: swiftc not found — install Xcode Command Line Tools (xcode-select --install)." >&2
  exit 1
fi

# Builds the binary and writes ./$PLIST with this checkout's absolute path baked in.
./build.sh --app

mkdir -p "$AGENTS"
# Reload cleanly if a previous version is already loaded.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
cp "$PLIST" "$AGENTS/$PLIST"
launchctl load -w "$AGENTS/$PLIST"

echo
echo "Installed. Menu-bar app is running and will start at login."
echo "  uninstall:  launchctl bootout gui/$(id -u)/$LABEL ; rm \"$AGENTS/$PLIST\""
echo "  logs:       /tmp/tmuxclaudewatcher.log"
