#!/bin/sh
# Builds Jog Scroll, installs it to ~/Applications, sets it to start at login, and launches it.
set -e
cd "$(dirname "$0")"
./build.sh

# Stop any running copy (menu bar app or a terminal `jog-scroll`) so the jog doesn't scroll twice.
pkill -x jog-scroll 2>/dev/null && sleep 1 || true

DEST="$HOME/Applications/JogScroll.app"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R build/JogScroll.app "$DEST"

"$DEST/Contents/MacOS/jog-scroll" login on
open "$DEST"
echo "Installed $DEST"
