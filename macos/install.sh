#!/bin/sh
# Builds Jog Scroll, installs it to ~/Applications, sets it to start at login, and launches it.
set -e
cd "$(dirname "$0")"
./build.sh

# Stop any running copy (menu bar app or a terminal `jog-scroll`) so the jog doesn't scroll twice.
# Unload the login item first, or launchd restarts the old copy as soon as it's stopped.
AGENT="$HOME/Library/LaunchAgents/local.jog-scroll.plist"
launchctl bootout "gui/$(id -u)/local.jog-scroll" 2>/dev/null || true
pkill -x jog-scroll 2>/dev/null && sleep 1 || true

DEST="$HOME/Applications/JogScroll.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R ../build/macos/JogScroll.app "$DEST"

"$DEST/Contents/MacOS/jog-scroll" login on
# Start it through launchd, so it's restarted after a crash from now on and not only after the next login.
launchctl bootstrap "gui/$(id -u)" "$AGENT" 2>/dev/null || open "$DEST"
echo "Installed $DEST"
