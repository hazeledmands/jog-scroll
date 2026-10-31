# Jog Scroll

Jog Scroll is a small app for macOS and Windows that turns a DJ controller's jog wheel into a scroll wheel. Spin the jog to scroll web pages, documents and code smoothly, with fine control when you turn slowly. It works with any MIDI controller that has a jog wheel: you teach it yours the first time it runs.

How it behaves:
- Turning the jog scrolls smoothly by a set amount per tick. At low settings, partial amounts are carried over so even slow turns move.
- While you touch the top of the jog, and for 1 second after you let go, scrolling is 10× faster. Touching it again within that second keeps it fast.
- While you hold Shift on your keyboard, the jog scrolls sideways instead. Turning it the way that normally scrolls up scrolls left.
- It notices the controller being plugged in or unplugged, and can show a notification when that happens.

## Controls (Windows)

On Windows, the jog wheel is one of the **controls** in the settings: things on the controller, and what each one does when it moves. A jog wheel scrolls, and it can be joined by faders and knobs that send their position to other programs as HTTP requests: to dim lights through [Hue Tray](https://github.com/hazeledmands/huetray), for example. Each program is a server in `servers`, and each control is an entry in `controls` with a list of `actions`:

```json
"servers": {
  "hue": {
    "type": "http",
    "url": "http://127.0.0.1:${file:%APPDATA%/hue-tray/config.json#apiPort}/api/v1/",
    "headers": { "Authorization": "Bearer ${file:%APPDATA%/hue-tray/config.json#apiToken}" }
  }
},
"controls": [
  {
    "name": "Jog",
    "type": "jog",
    "actions": [ { "type": "scroll", "wheelUnitsPerTick": 5 } ]
  },
  {
    "name": "Desk brightness",
    "actions": [
      { "server": "hue", "method": "PATCH", "path": "lights/Desk Anglepoise", "body": { "brightness": "$value" }, "range": [0, 100] },
      { "server": "hue", "method": "PATCH", "path": "rooms/Office", "body": { "brightness": "$value" }, "range": [0, 100] }
    ]
  }
]
```

Then teach it which jog, fader or knob to use: **Controls** in the menu, or `jog-scroll learn-control NAME`. For a jog wheel, touch its top and then spin it by its edge. For a fader or knob, move it all the way down and up, and it saves once you stop. It records the range the control covered, so each end of the control is each end of `range`.

**Learn Jog Wheel…** and `jog-scroll learn` teach it the first jog wheel in `controls`, and add one if there isn't one. The menu's **Invert Direction** and **Sensitivity** are for the jog wheels that scroll, in a submenu for each if there's more than one. Settings from before the jog wheel was a control (`touch`, `jog`, `wheelUnitsPerTick` and so on) are moved into one the first time it runs.

A server:

| key | default | meaning |
|---|---|---|
| `type` | `http` | the kind of server. `http` is the only one so far |
| `url` | | the start of every request's URL |
| `headers` | | headers sent with every request |

`url` and `headers` can include `${file:PATH#key}`, a top-level value from a JSON file, and `${env:NAME}`, an environment variable. The example uses this to read Hue Tray's port and token from Hue Tray's own settings, so there's nothing to copy across. Environment variables in `PATH`, like `%APPDATA%`, are expanded.

A control:

| key | default | meaning |
|---|---|---|
| `name` | | what the menu calls it |
| `type` | `fader` | `jog` for a jog wheel, which sends turns, or `fader` for a fader or knob, which sends its position |
| `actions` | | what it does whenever it moves |
| `invert` | false | for a jog, scroll the other way. For a fader, its top sends the lowest value, like most tempo faders |
| `touchMultiplier` (jog) | 10 | speed-up while the jog top is touched |
| `touchHoldSeconds` (jog) | 1.0 | how long the speed-up lasts after letting go |
| `centerThreshold` (jog) | 50 | values below this are clockwise turns, and values above are counter-clockwise |
| `midi`, `touch`, `fine`, `low`, `high` | | the learned control: its MIDI message, a jog's touch sensor, the CC with a fader's fine value (for high-resolution faders, which send two), and the lowest and highest values a fader sends |

An action that scrolls, for a jog wheel:

| key | default | meaning |
|---|---|---|
| `type` | | `scroll` |
| `wheelUnitsPerTick` | 5 | scroll distance per jog tick, in wheel units (120 = one mouse-wheel notch) |

An action that sends a request, for a fader or knob:

| key | default | meaning |
|---|---|---|
| `server` | | which server to send it to |
| `method` | `POST` | the HTTP method |
| `path` | | added to the server's `url`. Each part is escaped, so names can have spaces |
| `body` | none | JSON to send. A string that's exactly `"$value"` becomes the control's value as a number, and `$value` inside a longer string (or in `path`) is replaced as text |
| `range` | `[0, 1]` | the value at the bottom and the top of the control |
| `decimals` | 0 | how many decimal places to round the value to. Set it when `range` is small, like `[0, 1]` |
| `response` | none | where to find a number in the server's answer, to `show`: a key, or keys separated by dots for objects inside it (`scope.index`) |
| `show` | none | lights on the controller that show that number, or the value sent if there's no `response`: see below |

`show` lights the first *N* of a group of lights, where *N* is the number, and turns them all off `seconds` after the last change:

| key | default | meaning |
|---|---|---|
| `lights` | | the MIDI message for each light, in order, like `{"status": 149, "data1": 20}` |
| `on`, `off` | 127, 0 | the values that turn a light on and off. On some controllers, `on` is the color |
| `seconds` | 1 | how long they stay lit |

The lights are sent to the controller's MIDI output: `portName` with "In" at the end changed to "Out", or `outputPortName` if you set it. On the Reloop Ready, a pad's light uses the same message the pad sends when pressed. The right deck's pads are `status` 149 with `data1` 20–27, and the left deck's are probably 148 with the same numbers. Their `on` value is a color, two bits each of red, green and blue (`0b00RRGGBB`): 48 is red, 12 green, 3 blue, 15 cyan, 60 yellow and 63 white.

For example, with [Hue Tray](https://github.com/hazeledmands/huetray)'s scopes, a knob can choose which lights the faders change, and light as many pads as the scope's number:

```json
{
  "name": "Scope",
  "actions": [{
    "server": "hue", "method": "PUT", "path": "scope", "body": { "position": "$value" }, "decimals": 2,
    "response": "index",
    "show": {
      "lights": [
        {"status": 149, "data1": 20},
        {"status": 149, "data1": 21},
        {"status": 149, "data1": 22},
        {"status": 149, "data1": 23},
        {"status": 149, "data1": 24},
        {"status": 149, "data1": 25},
        {"status": 149, "data1": 26},
        {"status": 149, "data1": 27}
      ],
      "on": 15
    }
  }]
}
```

Requests to the same method and path go one at a time. If the control moves while one is on its way, the next request carries the newest value, and the fields of JSON bodies from different controls are merged. A fast sweep therefore sends only a few requests. A control sends its position whenever it moves, so after something else changes the setting, the control jumps it back to where the control is. Jog wheels can only scroll so far, and buttons and encoders don't work yet. To find which MIDI message a light uses, `jog-scroll monitor` shows what each pad sends.

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
| `portName` | Reloop Ready | MIDI input to listen to (part of its name is enough) |
| `connectionAlerts` | true | notify when the controller connects or disconnects |
| `outputPortName` (Windows) | | the MIDI output for the controller's lights, if it isn't `portName` with "In" changed to "Out" |

On Windows, the jog wheel's settings are in its control: see [Controls](#controls-windows). On macOS, they're at the top level:

| key | default | meaning |
|---|---|---|
| `touchMultiplier` | 10 | speed-up while the jog top is touched |
| `touchHoldSeconds` | 1.0 | how long the speed-up lasts after letting go |
| `pixelsPerTick` | 4 | scroll distance per jog tick, in pixels; decimals like `2.5` work |
| `invert` | false | flip the scroll direction |

## Terminal commands

Both versions have the same commands: `jog-scroll run` (scroll without the icon, logging to the terminal), `learn`, `monitor` (print every incoming MIDI message, for troubleshooting) and `login on` / `login off`. Each platform's README says where the program is.

## Repository layout

- `macos/`: the Swift app (`main.swift`) and its build, install and signing scripts
- `windows/`: the C#/.NET app and its build and install scripts
- `icon/`: the app icon, shared by both. `make-icon.swift` draws it, and `make-ico.ps1` converts it for Windows.

The two versions share no code, so the scrolling rules above are written twice: `JogEngine` in `macos/main.swift`, and in `windows/Jog.cs` (the jog wheel) and `ScrollOutput` in `windows/Outputs.cs` (the scrolling). When you change how scrolling behaves, change both and update this README. Controls are Windows-only so far, so the two versions' settings files differ.
