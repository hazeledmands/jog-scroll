#!/bin/sh
# Builds build/JogScroll.app from main.swift. Needs Apple's Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP=build/JogScroll.app
rm -rf "$APP" jog-scroll
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/jog-scroll" main.swift \
    -framework AppKit -framework CoreMIDI -framework ApplicationServices

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>         <string>local.jog-scroll</string>
    <key>CFBundleName</key>               <string>Jog Scroll</string>
    <key>CFBundleDisplayName</key>        <string>Jog Scroll</string>
    <key>CFBundleExecutable</key>         <string>jog-scroll</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
</dict>
</plist>
EOF

# Ad-hoc signature so macOS can remember the Accessibility permission.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
