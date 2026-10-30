# Jog Scroll for macOS

A menu bar app. See the [main README](../README.md) for how it behaves and for the settings.

## Install

You'll need Apple's Command Line Tools (`xcode-select --install`). Then, from the repo root, run:

```
macos/make-signing-cert.sh   # one time: creates a local signing certificate
macos/install.sh
```

`make-signing-cert.sh` adds a self-signed "Jog Scroll Local Signing" certificate to your login keychain. Every build is signed with it, so macOS treats a rebuilt app as the same app and keeps its Accessibility permission. Without the certificate, builds are signed ad-hoc and you'll need to approve the permission again after each rebuild.

`install.sh` builds `JogScroll.app` (into `build/macos`), copies it to `~/Applications`, sets it to start at login and launches it. To build without installing, run `macos/build.sh`.

The first time it runs, macOS asks for **Accessibility** permission, which it needs to control the mouse. Turn on **jog-scroll** under System Settings → Privacy & Security → Accessibility. Jog Scroll then restarts itself.

If scrolling stops after a rebuild, check that the signing certificate exists. Then turn Jog Scroll's Accessibility switch off and on again, or remove it from the list and add it back.

## Menu bar icon

- The dial icon is dimmed while the controller is unplugged, scrolling is paused, or Accessibility permission is missing.
- While fast mode is on, the dial turns filled.
- While you're teaching it the jog wheel, the prompts ("Touch the jog top", "Now spin the jog edge") show next to the icon.
- **Connection Alerts** shows a notification when the controller is plugged in or unplugged. To turn the sound off but keep the alerts, go to System Settings → Notifications → Jog Scroll. macOS hides notifications while your screen is mirrored or shared, unless **Allow notifications when mirroring or sharing the display** is on in that same settings pane.
- **Open Settings File** opens `config.json` in TextEdit.

## Terminal commands

Run these as `~/Applications/JogScroll.app/Contents/MacOS/jog-scroll <command>`:

- `run`: scroll without the menu bar icon, logging to the terminal
- `learn`: teach it the jog wheel
- `monitor`: print every incoming MIDI message, for troubleshooting
- `login on` / `login off`: start, or stop starting, at login

The login item is `~/Library/LaunchAgents/local.jog-scroll.plist`.
