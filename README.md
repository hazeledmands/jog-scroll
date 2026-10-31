# Jog Scroll

Jog Scroll is a small app for macOS and Windows that turns a DJ controller's jog wheel into a scroll wheel. Spin the jog to scroll web pages, documents and code smoothly, with fine control when you turn slowly. It works with any MIDI controller that has a jog wheel: you teach it yours the first time it runs.

How it behaves:
- Turning the jog scrolls smoothly by a set amount per tick. At low settings, partial amounts are carried over so even slow turns move.
- While you touch the top of the jog, and for 1 second after you let go, scrolling is 10× faster. Touching it again within that second keeps it fast.
- While you hold Shift on your keyboard, the jog scrolls sideways instead. Turning it the way that normally scrolls up scrolls left.
- It notices the controller being plugged in or unplugged, and can show a notification when that happens.

## Light controls (Windows)

Faders and knobs on the controller can also dim lights or change their color temperature, through [Hue Tray](https://github.com/hazeledmands/huetray)'s local API. Hue Tray has to be running on the same computer. Jog Scroll reads Hue Tray's port and token from Hue Tray's own settings, so there's nothing to copy across.

Add each control to `lightControls` in `config.json`:

```json
"lightControls": [
  { "name": "Desk brightness", "targets": ["lights/Desk Anglepoise", "rooms/Office"], "set": "brightness" },
  { "name": "Desk color temperature", "targets": ["lights/Desk Anglepoise"], "set": "colorTemp" }
]
```

Then teach it which fader or knob to use: **Light Controls** in the menu, or `jog-scroll learn-light NAME`. Move the control all the way down and up, and it saves once you stop. It records the range the control covered, so each end of the control is each end of the light.

| key | default | meaning |
|---|---|---|
| `name` | | what the menu calls it |
| `targets` | | what to change, as Hue Tray API paths: `lights/NAME`, `rooms/NAME`, `zones/NAME` or `home` |
| `set` | `brightness` | `brightness` (percent; the bottom turns the lights off) or `colorTemp` (kelvin) |
| `min`, `max` | 0–100 or 2000–6500 | the value at each end of the control |
| `invert` | false | for a control whose top sends the lowest value, like most tempo faders |
| `midi`, `fine`, `low`, `high` | | the learned control: its MIDI message, the CC with its fine value (for high-resolution faders, which send two), and the lowest and highest values it sends |

A control sets the lights to match its position whenever it moves, so after the lights change some other way, it jumps them back to where the control is. Setting the color temperature turns lights on, as it does everywhere in Hue Tray.

## Install

| | Runs as | Install |
|---|---|---|
| macOS | a menu bar app | [macos/README.md](macos/README.md) |
| Windows | a notification-area (tray) app | [windows/README.md](windows/README.md) |

On both, the first run asks you to teach it your jog wheel: touch the top of the jog, then spin it by its edge. The icon's menu has the same items on both: Scrolling On, Invert Direction, Sensitivity, Connection Alerts, Learn Jog Wheel…, Open Settings File, Start at Login and Quit.

## Settings

Settings are in `config.json`, and changes take effect within a couple of seconds. It's in `~/Library/Application Support/jog-scroll/` on macOS and `%APPDATA%\jog-scroll\` on Windows.

| key | default | meaning |
|---|---|---|
| `touchMultiplier` | 10 | speed-up while the jog top is touched |
| `touchHoldSeconds` | 1.0 | how long the speed-up lasts after letting go |
| `pixelsPerTick` (macOS) | 4 | scroll distance per jog tick, in pixels; decimals like `2.5` work |
| `wheelUnitsPerTick` (Windows) | 5 | scroll distance per jog tick, in wheel units (120 = one mouse-wheel notch) |
| `invert` | false | flip the scroll direction |
| `connectionAlerts` | true | notify when the controller connects or disconnects |
| `portName` | Reloop Ready | MIDI input to listen to (part of its name is enough) |

## Terminal commands

Both versions have the same commands: `jog-scroll run` (scroll without the icon, logging to the terminal), `learn`, `monitor` (print every incoming MIDI message, for troubleshooting) and `login on` / `login off`. Each platform's README says where the program is.

## Repository layout

- `macos/`: the Swift app (`main.swift`) and its build, install and signing scripts
- `windows/`: the C#/.NET app and its build and install scripts
- `icon/`: the app icon, shared by both. `make-icon.swift` draws it, and `make-ico.ps1` converts it for Windows.

The two versions share no code, so the scrolling rules above are written twice: `JogEngine` in `macos/main.swift` and in `windows/Engine.cs`. When you change how scrolling behaves, change both and update this README.
