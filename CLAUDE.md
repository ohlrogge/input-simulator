# CLAUDE.md

## Project context

macOS menu bar utility that simulates keyboard input character by character. Primary use case: pasting clipboard text (typically R or Claude code snippets) into a **FortiClient RDP session running in a browser**, from a **German QWERTZ MacBook**. Normal paste is blocked in that environment.

## Build

Use `./install.sh` — it builds a Release binary via `xcodebuild` and copies the `.app` to `~/Applications`. There is no `swift build` / CLI build path (macOS app with entitlements and a menu bar lifecycle).

If `xcodebuild` fails with an `xcode-select` error, the active developer directory is pointing at Command Line Tools instead of Xcode: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

After every rebuild, macOS revokes the Accessibility trust for the new binary. Always run from `~/Applications/InputSimulator.app` to keep the permission stable.

## Architecture

All keystroke logic lives in `KeyboardSimulator.swift`. Two paths:

- **macOS mode** (`rdpMode: false`): injects characters as Unicode strings via `CGEvent.keyboardSetUnicodeString`. Works for any character in any macOS app.
- **RDP mode** (`rdpMode: true`): uses virtual key codes from the current keyboard layout (`buildCharacterMap`). Exception: characters that require the Option/Alt modifier (e.g. `[ ] { } \ | @` on German QWERTZ) are routed through **Alt+numpad sequences** instead, because browsers intercept `Option+key` CGEvents before the HTML5 RDP client sees them. Alt+numpad is forwarded correctly by browser-based RDP clients and is keyboard-layout-independent on the Windows side.

`~` is a dead key on German QWERTZ and never enters the charMap, so it always falls through to the Alt+numpad path automatically.

## Key files

- `KeyboardSimulator.swift` — character mapping and keystroke posting
- `MenuBarController.swift` — menu, hotkey wiring, symbol shortcut buttons
- `HotkeyManager.swift` — global `⌃⌥⌘V` hotkey registration
