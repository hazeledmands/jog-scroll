#!/bin/sh
# Builds build/JogScroll.app from main.swift. Needs Apple's Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP=build/JogScroll.app
rm -rf "$APP" jog-scroll
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/jog-scroll" main.swift \
    -framework AppKit -framework CoreMIDI -framework ApplicationServices -framework UserNotifications

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

# Sign with the local certificate from make-signing-cert.sh so the Accessibility permission
# survives rebuilds. Without it, fall back to an ad-hoc signature (permission resets each build).
IDENTITY=$(security find-identity -p codesigning 2>/dev/null \
    | awk '/"Jog Scroll Local Signing"/ { print $2; exit }')
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "Note: no \"Jog Scroll Local Signing\" certificate; signing ad-hoc. Run ./make-signing-cert.sh to fix."
    codesign --force --sign - "$APP"
fi
echo "Built $(pwd)/$APP"
