# Jog Scroll for Windows

A notification-area (tray) app. See the [main README](../README.md) for how it behaves and for the settings.

## Install

You'll need the .NET 8 SDK (`winget install Microsoft.DotNet.SDK.8`). From the repo root, run:

```
powershell -ExecutionPolicy Bypass -File windows\install.ps1
```

This builds Jog Scroll (into `build\windows`), copies it to `%LOCALAPPDATA%\Programs\JogScroll`, sets it to start at login and launches it. Windows doesn't need an Accessibility permission. To build without installing, run `windows\build.ps1`.

Windows won't run these scripts from a WSL folder (`\\wsl.localhost\...`), so copy or clone the repo onto a Windows drive first.

## Tray icon

- The dial icon sits in the notification area, and a left or right click opens the menu. You may need to drag it out of the hidden-icons area (^) so it stays visible.
- It's dimmed while the controller is unplugged or scrolling is paused, and filled while fast mode is on.
- While you're teaching it the jog wheel, the prompts appear as notifications and in the icon's tooltip, because Windows can't show text next to a tray icon.
- **Open Settings File** opens `config.json` in Notepad.

## Things that work differently on Windows

- **Sensitivity is in wheel units, not pixels.** Windows measures scrolling in wheel units: one mouse-wheel notch is 120. The default is 5 per tick. Browsers and most modern apps scroll smoothly at small values. A few older apps only move once they've received a full notch, so they'll feel slow unless you raise it.
- **Shift scrolls sideways only in apps that support Shift + mouse wheel.** While Shift is held, Jog Scroll scrolls the same way a real mouse wheel does, and each app decides whether that means sideways. Browsers, File Explorer and most editors do.
- Windows won't let a normal program send scrolling to a window that's running as administrator.

## Terminal commands

The terminal commands are a separate console program, `jog-scroll.exe`, next to `JogScroll.exe` in `%LOCALAPPDATA%\Programs\JogScroll`:

- `jog-scroll run`: scroll without the tray icon, logging to the terminal
- `jog-scroll learn`: teach it the jog wheel
- `jog-scroll monitor`: print every incoming MIDI message, for troubleshooting
- `jog-scroll login on` / `login off`: start, or stop starting, at login

The login item is a "Jog Scroll" entry under `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`.

## Sharing the controller with other programs

Older versions of Windows let only one program use a MIDI device at a time. On those, Jog Scroll and your DJ software can't both have the controller open. Jog Scroll only opens the controller it's set up for, and the menu says when another program is using it. It connects automatically once that program lets go.

Windows 11 with the Windows MIDI Service (the `midisrv` service) lets several programs share a device. That service also lists each device twice under the same name, so Jog Scroll opens only one input per name. A side effect is that two identical controllers would count as one.
