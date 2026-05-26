# Input Simulator

> **⚠️ Experimental — personal use only.**  
> This tool was built for a specific personal workflow and is not a polished product. It carries no guarantees and may behave unexpectedly in other environments. Use at your own risk.

macOS menu bar utility that types clipboard content as simulated keystrokes — useful for RDP sessions or any window where paste is blocked.

## Features

- **Paste via typing** — reads the clipboard and replays it keystroke by keystroke
- **Global hotkey** — `⌃⌥⌘V` triggers typing from anywhere
- **ESC to cancel** — stops mid-way through a long paste
- **Typing speed** — Slow (100 ms), Normal (40 ms), Fast (15 ms), or a custom value (≥ 5 ms)
- **Start delay** — configurable pause before the first keystroke (100 / 300 / 500 / 750 ms), giving you time to click into the target window
- **Windows RDP Mode** — uses Alt+numpad sequences for non-ASCII characters (Umlauts, etc.) so the correct glyphs arrive regardless of the Windows keyboard layout; leave it off for regular macOS apps
- **Symbol shortcuts** — `[ ] { } \ |` buttons in the main menu for quick insertion without the Windows symbol table

## Requirements

- macOS 13 Ventura or later
- **Accessibility permission** — grant it in *System Settings → Privacy & Security → Accessibility*; the app will prompt on first launch

## Build

Open `InputSimulator.xcodeproj` in Xcode and press `⌘R`.  
The app is ad-hoc signed and sandboxing is disabled — no notarization needed for personal use.

> **Note:** Every time Xcode rebuilds the binary macOS revokes the Accessibility trust for the new binary. Re-toggle the permission in System Settings after each rebuild, or copy the built `.app` to `~/Applications` and use that copy going forward.

## Usage

1. Copy text to the clipboard.
2. Click into the target window (the start delay gives you time to do this after pressing the hotkey).
3. Press `⌃⌥⌘V` — or open the menu bar icon and choose **Paste via Typing**.
4. Press `ESC` at any time to stop.

## Logs

Logs are written to:

```
~/Library/Logs/InputSimulator.log
```

The log is cleared each time the app launches. To tail it live:

```bash
tail -f ~/Library/Logs/InputSimulator.log
```
