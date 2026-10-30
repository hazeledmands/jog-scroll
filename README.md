# Jog Scroll

Jog Scroll is a menu bar app that turns a DJ controller's jog wheel into mouse-wheel scrolling. It's a standalone replacement for the Bome MIDI Translator "jog scroll" project.

How it behaves (same as the Bome rules):
- Turning the jog scrolls by the number of ticks the controller reports. Values below 50 count as clockwise, and values near 128 count as counter-clockwise.
- Unlike Bome, which scrolls whole lines, Jog Scroll scrolls smoothly by a set number of pixels per tick (4 by default). At low settings, partial pixels are carried over so slow turns still move.
- While you touch the top of the jog, and for 1 second after you let go, scrolling is 10× faster.
- One change from Bome: touching the jog again inside that 1-second window keeps it fast. (In Bome, the old timer would still switch fast mode off.)

## Install

You'll need Apple's Command Line Tools (`xcode-select --install`). Then run:

```
./install.sh
```

This builds `JogScroll.app`, copies it to `~/Applications`, sets it to start at login and launches it.

The first time it runs, macOS asks for **Accessibility** permission, which it needs to control the mouse. Turn on **jog-scroll** under System Settings → Privacy & Security → Accessibility. Jog Scroll then restarts itself.

After a rebuild, macOS may treat it as a new app. If scrolling stops, turn its Accessibility switch off and on again, or remove it from the list and add it back.

## Menu bar icon

- The dial icon is dimmed while the controller is unplugged, scrolling is paused, or Accessibility permission is missing.
- While fast mode is on, the dial turns filled.
- The menu has these items:
  - **Scrolling On**: pause or resume scrolling
  - **Invert Direction**: flip which way it scrolls
  - **Sensitivity**: how many pixels each jog tick scrolls
  - **Learn Jog Wheel…**: teach it a jog wheel (follow the prompts next to the icon)
  - **Open Settings File**
  - **Start at Login**
  - **Quit Jog Scroll**

## Settings

Settings are in `~/Library/Application Support/jog-scroll/config.json`, and changes take effect within a couple of seconds:

| key | default | meaning |
|---|---|---|
| `touchMultiplier` | 10 | speed-up while the jog top is touched |
| `touchHoldSeconds` | 1.0 | how long the speed-up lasts after letting go |
| `pixelsPerTick` | 4 | scroll distance per jog tick; decimals like `2.5` work |
| `invert` | false | flip the scroll direction |
| `portName` | Reloop Ready | MIDI input to listen to (part of its name is enough) |

## Terminal commands

Run these as `~/Applications/JogScroll.app/Contents/MacOS/jog-scroll <command>`:

- `run`: scroll without the menu bar icon, logging to the terminal
- `learn`: teach it the jog wheel
- `monitor`: print every incoming MIDI message, for troubleshooting
- `login on` / `login off`: start, or stop starting, at login

The login item is `~/Library/LaunchAgents/local.jog-scroll.plist`.
