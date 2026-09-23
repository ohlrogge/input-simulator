# CLAUDE.md

## Project context

macOS menu bar utility that simulates keyboard input character by character. Primary use case: pasting clipboard text (typically R or Claude code snippets) into a **FortiClient RDP session running in a browser**, from a **German QWERTZ MacBook**. Normal paste is blocked in that environment.

## Build

Use `./install.sh` — it builds a Release binary via `xcodebuild` and copies the `.app` to `~/Applications`. There is no `swift build` / CLI build path (macOS app with entitlements and a menu bar lifecycle).

If `xcodebuild` fails with an `xcode-select` error, the active developer directory is pointing at Command Line Tools instead of Xcode: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.

After every rebuild, macOS revokes the Accessibility trust for the new binary. Always run from `~/Applications/InputSimulator.app` to keep the permission stable.

`~/Applications` is the only copy that should exist. Stray copies are a recurring source of "the menu item is missing" confusion, because each one puts its own icon in the menu bar and Spotlight prefers `/Applications`. When a menu change does not show up, check what is actually running before touching the code:

```bash
ps -Ao pid,lstart,comm | grep InputSimulator | grep -v grep
```

Instances started from Xcode run out of DerivedData and are held by `debugserver` — they survive `kill -9` and have to be stopped with Xcode's Stop button.

## Architecture

All keystroke logic lives in `KeyboardSimulator.swift`. The `TargetSystem` enum selects one of two paths; the user picks it in the menu under **Zielsystem** (persisted as `targetSystem` in UserDefaults, migrated from the older `windowsRdpMode` boolean):

- **`.macOS`**: injects characters as Unicode strings via `CGEvent.keyboardSetUnicodeString`. Works for any character in any macOS app — **and in the native Windows App**, see below.
- **`.rdpBrowser`**: uses virtual key codes from the current keyboard layout (`buildCharacterMap`). Exception: characters that require the Option/Alt modifier (e.g. `[ ] { } \ | @` on German QWERTZ) are routed through **Alt+numpad sequences** instead, because browsers intercept `Option+key` CGEvents before the HTML5 RDP client sees them. Alt+numpad is forwarded correctly by browser-based RDP clients and is keyboard-layout-independent on the Windows side.

Dead keys take the same Alt+numpad detour. On German QWERTZ `` ` ``, `´`, `^`, `~` and `¨` are dead: they emit nothing until the next character arrives to combine with, so posting them as key codes reorders the output (` ```{ ` came out as `` ``{` ``, and a trailing ` ``` ` lost its third backtick). They are detected in `buildCharacterMap` by translating each key *without* `kUCKeyTranslateNoDeadKeysMask` — a dead key yields no characters and leaves a pending dead-key state — and flagged as `KeyStroke.isDead`.

Note that dead keys **do** enter the charMap: the map is built *with* `kUCKeyTranslateNoDeadKeysMask`, which resolves them to their base character. `~` only avoided the problem by accident, because it needs Option and was already being rerouted.

Alt+numpad uses the short OEM form (`Alt+35`, no leading zero), verified on Windows 11 Western locale.

## Throughput: Blockgröße

`CGEvent.keyboardSetUnicodeString` takes a string, not a single character, so the `.macOS` path can put several characters into one key event. The **Blockgröße** menu sets how many (`chunkSize` in UserDefaults, default 1 = one event per character). At 15 ms typing speed, 1000 characters cost ~19 s one-by-one versus ~1 s in blocks of 20, because the per-character delay and the 4 ms key hold are paid per *event*, not per character.

This is the lever to pull when the receiving side is the bottleneck: the RDP client and the remote input buffer get a handful of text events instead of thousands of keystrokes. Return and Tab stay real key presses and flush the pending block, so ordering is preserved.

It does **not** apply to `.rdpBrowser` — that client reads one virtual key code per character, so batching is impossible there. Lowering the typing delay is the only lever in that mode.

## Native Windows App: set the connection to Unicode keyboard mode

The second RDP system runs in Microsoft's **Windows App** rather than a browser. It works with `Zielsystem = macOS`, but **only** if the connection's *keyboard mode* is set to **Unicode** (connection settings → keyboard mode; the default is Scancode). Do not try to fix this in code — it is a client setting.

In **Scancode** mode the client derives the scancode from the real hardware modifier state. Synthetic CGEvents carry no such state, so the client resolves the event to a *character* and falls back to typing it as an Alt+numpad sequence of its own — and that sequence loses its Alt inside the session. The tell-tale symptom is the **decimal ASCII code of the intended character** appearing as literal digits: `=` → `61`, `;` → `59`, `(` → `40`, `#` → `35`, `[` → `91`.

That fallback swallows everything, so no event-level trick on the macOS side gets around it. All of these were tried and produce identical output in Scancode mode: modifiers as `keyDown`/`keyUp`, as `.flagsChanged`, from a `.hidSystemState` event source, with settle delays, right Option and Ctrl+Alt for AltGr, and Alt+numpad in both the short and the `Alt+0NNN` form. `.macOS` mode in Scancode mode yields a run of `a`s.

The Windows session uses the German layout (DEU), so key positions match the Mac side for unmodified and shifted keys — but not for the AltGr characters (`[` is `AltGr+8` on Windows, `Option+5` on the Mac).

## Key files

- `KeyboardSimulator.swift` — character mapping and keystroke posting
- `MenuBarController.swift` — menu, hotkey wiring, symbol shortcut buttons
- `HotkeyManager.swift` — global `⌃⌥⌘V` hotkey registration
