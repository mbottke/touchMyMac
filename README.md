# TouchMyMac

TouchMyMac is a user-space touchscreen driver for macOS.

Many USB touch displays expose touch input through standard HID descriptors and work immediately on Windows, but do nothing on macOS. TouchMyMac reads that HID stream in user space, turns it into touch state, and injects mouse or keyboard events so an external touchscreen can control your Mac.

## What It Supports

- Single-finger tap to click
- Single-finger drag scrolling with adjustable speed
- Hold then move to drag
- Two-finger secondary click
- Two-finger pinch magnification
- Three-finger swipe up for Mission Control
- Four-finger swipe up/down to show or hide a floating keyboard
- Four-finger swipe left to trigger a configurable shortcut sequence
- Five-finger hold to keep a key or key chord pressed
- Live diagnostics and gesture debugging tools

## Current Gesture Model

The default interaction is tuned to feel closer to direct touch than a traditional trackpad translation layer.

- Tap to click
- Drag to scroll
- Hold briefly, then move to drag content or selections
- Rest one finger and tap another nearby finger for right click
- Pinch with two fingers to zoom
- Swipe up with three fingers for Mission Control
- Swipe up with four fingers to show the floating keyboard
- Swipe down with four fingers to hide the floating keyboard

The Settings window lets you customize:

- Scroll speed
- Hold duration
- Double-click distance
- Scroll inertia amount and decay
- Error resistance for noisy touch panels
- Five-finger hold shortcut mapping
- Four-finger left swipe shortcut sequence

## Floating Keyboard

The built-in floating keyboard is designed for occasional touchscreen text entry on macOS.

- Movable and closable panel
- Letter layout plus a symbol layer
- Shift, space, delete, and return
- Triggered by four-finger swipe up
- Hidden by four-finger swipe down

## Requirements

- macOS 12 or later
- A USB touchscreen that exposes touch input through HID
- Accessibility permission enabled for TouchMyMac

TouchMyMac should work with many touchscreens that already work on Windows, but hardware quality varies and some panels are noisier than others.

Tested devices from the original project include:

- Iiyama TF3222MC
- Iiyama T2336MSC-B2
- 3M C4667PW

## Build

Open the project in Xcode:

```bash
open TouchMyMac.xcodeproj
```

Or build from the command line:

```bash
xcodebuild \
  -project TouchMyMac.xcodeproj \
  -scheme TouchMyMac \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## Run

1. Build and launch `TouchMyMac.app`.
2. Open Settings and grant Accessibility access.
3. Connect your touchscreen.
4. Assign the target screen if needed.
5. Start interacting directly on the display.

If input is unstable, use the Diagnostics pane to inspect connection state, gesture recognition, and live touch counters.

## Project Structure

- `TouchMyMac/`
  App UI, settings, status item integration, diagnostics, and floating keyboard
- `TouchUpCore/`
  HID parsing, touch tracking, gesture recognition, and event injection
- `scripts/`
  Small project utilities

## Notes

- TouchMyMac works entirely in user space.
- Accessibility permission is required because the app injects input events into macOS.
- Some gesture behavior is intentionally conservative to reduce accidental activation on noisy panels.

## License

See [LICENSE](LICENSE).
