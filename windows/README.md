# Jog Scroll for Windows

A Windows version of Jog Scroll, which turns a DJ controller's jog wheel into mouse-wheel scrolling. It works like the macOS app (see the [main README](../README.md)), with the differences below.

## Install

You'll need the .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`). From a copy of this repo on a Windows drive, run:

```
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

This builds Jog Scroll, copies it to `%LOCALAPPDATA%\Programs\JogScroll`, sets it to start at login and launches it. Windows doesn't need an Accessibility permission. To build without installing, run `windows\build.ps1`. The programs go in `build\windows`.

Windows won't run these scripts from a WSL folder (`\\wsl.localhost\...`), so copy or clone the repo onto a Windows drive first.

## How it differs from the Mac version

- **Tray icon instead of a menu bar icon.** The dial icon sits in the notification area, and a left or right click opens the same menu. You may need to drag it out of the hidden-icons area (^) so it stays visible. It's dimmed while the controller is unplugged or scrolling is paused, and filled while fast mode is on.
- **Sensitivity is in wheel units, not pixels.** Windows measures scrolling in wheel units: one mouse-wheel notch is 120. The default is 5 per tick. Browsers and most modern apps scroll smoothly at small values. A few older apps only move once they've received a full notch, so they'll feel slow unless you raise it.
- **Shift scrolls sideways only in apps that support Shift + mouse wheel.** While Shift is held, Jog Scroll scrolls the same way a real mouse wheel does, and each app decides whether that means sideways. Browsers, File Explorer and most editors do.
- **Learning happens through notifications.** Windows can't show text next to a tray icon, so the "touch the jog top" and "now spin the jog edge" prompts appear as notifications. They also show in the icon's tooltip.
- **Terminal commands are a separate program**, `jog-scroll.exe`, next to `JogScroll.exe`:
  - `jog-scroll run`: scroll without the tray icon, logging to the terminal
  - `jog-scroll learn`: teach it the jog wheel
  - `jog-scroll monitor`: print every incoming MIDI message, for troubleshooting
  - `jog-scroll login on` / `login off`: start, or stop starting, at login (a "Jog Scroll" entry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`)
- Windows won't let a normal program send scrolling to a window that's running as administrator.

## Sharing the controller with other programs

Older versions of Windows let only one program use a MIDI device at a time. On those, Jog Scroll and your DJ software can't both have the controller open. Jog Scroll only opens the controller it's set up for, and the menu says when another program is using it. It connects automatically once that program lets go.

Windows 11 with the Windows MIDI Service (the `midisrv` service) lets several programs share a device. That service also lists each device twice under the same name, so Jog Scroll opens only one input per name. A side effect is that two identical controllers would count as one.

## Settings

Settings are in `%APPDATA%\jog-scroll\config.json`, and changes take effect within a couple of seconds. The keys match the Mac version, except that `wheelUnitsPerTick` (default 5) replaces `pixelsPerTick`.
