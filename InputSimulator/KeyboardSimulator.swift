import Carbon
import CoreGraphics
import Foundation
import os

private let log = Logger(subsystem: "com.niklas.inputsimulator", category: "keyboard")

final class CancellationToken {
    private let lock = NSLock()
    private var _cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

private struct KeyStroke {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

// Which system receives the keystrokes. Raw values are persisted in UserDefaults.
enum TargetSystem: Int {
    case macOS         = 0 // Unicode string injection
    case rdpBrowser    = 1 // RDP client running inside a browser (FortiClient)
    case rdpWindowsApp = 2 // native Windows App on macOS

    var label: String {
        switch self {
        case .macOS:         return "macOS"
        case .rdpBrowser:    return "RDP im Browser"
        case .rdpWindowsApp: return "RDP Windows App"
        }
    }
}

// Builds a character → (keyCode, modifiers) map from the current keyboard layout.
// RDP reads the virtual key code from CGEvents, not the Unicode string, so we must
// send the correct key code for each character rather than using virtualKey=0.
private func buildCharacterMap() -> [Character: KeyStroke] {
    flog("Building character map from current keyboard layout")
    var map: [Character: KeyStroke] = [:]

    // TISCopyCurrentKeyboardLayoutInputSource gives the physical layout even when an IME is active.
    let source = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
    guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
        flog("Failed to get keyboard layout data")
        return map
    }

    let cfData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(cfData) else {
        flog("Failed to read keyboard layout bytes")
        return map
    }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

    let modCombos: [(UInt32, CGEventFlags)] = [
        (0, []),
        (UInt32(shiftKey >> 8), .maskShift),
        (UInt32(optionKey >> 8), .maskAlternate),
        (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
    ]

    let kbType = UInt32(LMGetKbdType())

    for keyCode: UInt16 in 0..<128 {
        for (modState, flags) in modCombos {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var charCount = 0

            let status = UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                modState,
                kbType,
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                chars.count,
                &charCount,
                &chars
            )

            guard status == noErr,
                  charCount == 1,
                  chars[0] >= 0x20,
                  let scalar = Unicode.Scalar(UInt32(chars[0]))
            else { continue }

            let char = Character(scalar)
            if map[char] == nil {
                map[char] = KeyStroke(keyCode: CGKeyCode(keyCode), flags: flags)
            }
        }
    }

    flog("Character map built: \(map.count) entries")
    return map
}

enum KeyboardSimulator {
    private static let specialKeys: [Character: CGKeyCode] = [
        "\n": 0x24, // Return
        "\r": 0x24, // Return
        "\t": 0x30, // Tab
    ]

    private static let charMap: [Character: KeyStroke] = buildCharacterMap()

    // Must be called once on the main thread before any typing begins.
    // TIS APIs are main-thread-only; this forces charMap to initialize there.
    static func warmUp() {
        assert(Thread.isMainThread)
        _ = charMap
        flog("KeyboardSimulator warmed up: \(charMap.count) characters mapped")
    }

    static func type(_ text: String, delayMs: Int, token: CancellationToken, target: TargetSystem = .macOS) {
        flog("Typing started: \(text.count) chars, delay=\(delayMs)ms, target=\(target.label)")
        var typed = 0
        var skipped = 0

        for (index, char) in text.enumerated() {
            guard !token.isCancelled else {
                flog("Typing cancelled at character \(index)/\(text.count)")
                return
            }
            if let keyCode = specialKeys[char] {
                postKey(KeyStroke(keyCode: keyCode, flags: []))
                typed += 1
            } else {
                switch target {
                case .macOS:
                    // Send the Unicode string directly — works for all characters including
                    // Umlauts, regardless of the active keyboard layout.
                    postUnicode(char)
                    typed += 1
                case .rdpBrowser:
                    if typeViaRdp(char, native: false) { typed += 1 } else { skipped += 1 }
                case .rdpWindowsApp:
                    if typeViaRdp(char, native: true) { typed += 1 } else { skipped += 1 }
                }
            }

            if index % 50 == 49 {
                flog("Progress: \(index + 1)/\(text.count) characters")
            }

            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        }

        flog("Typing complete: \(typed) typed, \(skipped) skipped")
    }

    // Types one character into an RDP session. Prefers key codes from charMap (RDP reads
    // virtual key codes, not the Unicode string). Exception: chars that require the
    // Option/Alt modifier (e.g. [ ] { } \ | on QWERTZ) go through Alt+numpad instead —
    // browsers intercept Option+key before the HTML5 RDP client sees it, and on the Windows
    // side those characters sit on entirely different keys anyway. Alt+numpad is forwarded
    // correctly by both clients and is layout-independent on Windows.
    // ~ is a dead key on QWERTZ and never enters charMap, so it falls through to Alt+numpad.
    //
    // `native` selects the Windows App variant. That client ignores synthetic Shift presses
    // entirely (`;` arrived as `,`, `=` as `0`, `(` as `8`), so there we only use the key code
    // for keys that need *no* modifier at all and route everything else — including capitals —
    // through Alt+numpad. That leaves Alt as the only modifier that has to work.
    //
    // Returns false if the character has no usable route.
    private static func typeViaRdp(_ char: Character, native: Bool) -> Bool {
        let scalar = char.unicodeScalars.first

        if native {
            if let stroke = charMap[char], stroke.flags.isEmpty {
                postKeyNative(stroke)
                return true
            }
            if let scalar, scalar.value >= 32 && scalar.value <= 255 {
                postAltNumpad(ascii: scalar.value, native: true)
                return true
            }
            flog("Skipping unmapped character U+\(String(scalar?.value ?? 0, radix: 16))")
            return false
        }

        if let stroke = charMap[char] {
            if stroke.flags.contains(.maskAlternate),
               let scalar, scalar.value >= 32 && scalar.value <= 127 {
                postAltNumpad(ascii: scalar.value, native: false)
            } else {
                postKey(stroke)
            }
            return true
        }
        if let scalar, scalar.value >= 32 && scalar.value <= 255 {
            postAltNumpad(ascii: scalar.value, native: false)
            return true
        }
        flog("Skipping unmapped character U+\(String(scalar?.value ?? 0, radix: 16))")
        return false
    }

    // Diagnostic for the native Windows App: types one line per modifier technique, each
    // labelled, so a single run shows which technique the client actually honours.
    // Labels use only unmodified keys (lowercase letters, digits, space), which are known
    // to arrive correctly. The Windows session uses the German layout, so the expected
    // character per line is: Shift+8 → "(", Alt+numpad → "#", AltGr+8 → "[".
    static func runWindowsAppDiagnostics(token: CancellationToken) {
        guard let eight = charMap["8"] else {
            flog("Diagnostics: key '8' not found in charMap")
            return
        }
        let key = eight.keyCode
        let shifted = KeyStroke(keyCode: key, flags: .maskShift)

        // Each entry: label, then the technique that types the test character.
        let tests: [(String, () -> Void)] = [
            ("1 flagsonly ", {                                  // flags on the key event only
                postRaw(key, down: true,  flags: .maskShift, source: nativeSource)
                postRaw(key, down: false, flags: .maskShift, source: nativeSource)
            }),
            ("2 keydownmod ", { postKey(shifted) }),            // Shift as keyDown/keyUp (browser path)
            ("3 flagschanged ", { postKeyNative(shifted) }),    // Shift as .flagsChanged
            ("4 numpad ", { postAltNumpad(ascii: 35, native: true) }),
            ("5 numpadzero ", { postAltNumpadPadded(ascii: 35) }),
            ("6 rightopt ", { postWithModifier(key, modifier: 0x3D, flags: .maskAlternate) }),
            ("7 ctrlalt ", { postWithModifier(key, modifier: 0x3B, flags: [.maskControl, .maskAlternate],
                                              extraModifier: 0x3A) }),
        ]

        flog("Windows App diagnostics: \(tests.count) techniques")
        for (label, technique) in tests {
            guard !token.isCancelled else {
                flog("Diagnostics cancelled")
                return
            }
            typePlain(label)
            technique()
            postKey(KeyStroke(keyCode: 0x24, flags: [])) // Return
            sleepMs(60)
        }
        flog("Windows App diagnostics complete")
    }

    // Types a string using only unmodified key codes; anything needing a modifier is skipped.
    private static func typePlain(_ text: String) {
        for char in text {
            guard let stroke = charMap[char], stroke.flags.isEmpty else { continue }
            postRaw(stroke.keyCode, down: true,  flags: [], source: nativeSource)
            sleepMs(keyGapMs)
            postRaw(stroke.keyCode, down: false, flags: [], source: nativeSource)
            sleepMs(keyGapMs)
        }
    }

    // Presses `modifier` (and optionally a second one), then the key, via .flagsChanged.
    private static func postWithModifier(_ keyCode: CGKeyCode, modifier: CGKeyCode,
                                         flags: CGEventFlags, extraModifier: CGKeyCode? = nil) {
        postModifier(modifier, flags: flags)
        if let extra = extraModifier { postModifier(extra, flags: flags) }
        postRaw(keyCode, down: true,  flags: flags, source: nativeSource)
        sleepMs(keyGapMs)
        postRaw(keyCode, down: false, flags: flags, source: nativeSource)
        if let extra = extraModifier { postModifier(extra, flags: []) }
        postModifier(modifier, flags: [])
    }

    // Alt+0NNN — the ANSI four-digit form, for comparison against the short OEM form.
    private static func postAltNumpadPadded(ascii: UInt32) {
        postModifier(0x3A, flags: .maskAlternate)
        for d in [0, ascii / 100, (ascii % 100) / 10, ascii % 10] {
            guard let kc = numpadCodes[d] else { continue }
            postRaw(kc, down: true,  flags: [.maskAlternate, .maskNumericPad], source: nativeSource)
            sleepMs(keyGapMs)
            postRaw(kc, down: false, flags: [.maskAlternate, .maskNumericPad], source: nativeSource)
            sleepMs(keyGapMs)
        }
        postModifier(0x3A, flags: [])
    }

    // Types a single character via unicode string injection — works in macOS apps.
    static func typeViaCharMap(_ char: Character) {
        if let keyCode = specialKeys[char] {
            postKey(KeyStroke(keyCode: keyCode, flags: []))
        } else {
            postUnicode(char)
        }
    }

    // Types a single symbol via Windows Alt+numpad — works in Windows RDP.
    static func typeSymbol(_ char: Character, native: Bool = false) {
        guard let scalar = char.unicodeScalars.first, scalar.value <= 127 else {
            flog("typeSymbol: unsupported character '\(char)'")
            return
        }
        flog("typeSymbol: '\(char)' (ASCII \(scalar.value)) via Alt+numpad, native=\(native)")
        postAltNumpad(ascii: scalar.value, native: native)
    }

    // Sends Alt+XXX on the numpad without leading zeros — Windows 11 accepts OEM short-form.
    // Verified on Windows 11 Western locale; saves 1-2 numpad events per character.
    // In native mode Alt is held via .flagsChanged (see postModifier) and the digit events
    // carry .maskNumericPad, because the Windows App distinguishes numpad from number-row keys.
    private static let numpadCodes: [UInt32: CGKeyCode] = [
        0: 0x52, 1: 0x53, 2: 0x54, 3: 0x55,
        4: 0x56, 5: 0x57, 6: 0x58, 7: 0x59,
        8: 0x5B, 9: 0x5C,
    ]

    private static func postAltNumpad(ascii: UInt32, native: Bool) {
        var n = ascii
        var digits: [UInt32] = []
        repeat { digits.insert(n % 10, at: 0); n /= 10 } while n > 0

        let digitFlags: CGEventFlags = native ? [.maskAlternate, .maskNumericPad] : .maskAlternate
        let source = native ? nativeSource : nil

        if native { postModifier(0x3A, flags: .maskAlternate) }        // Left Alt down
        else      { postRaw(0x3A, down: true, flags: .maskAlternate) }

        for d in digits {
            if let kc = numpadCodes[d] {
                postRaw(kc, down: true,  flags: digitFlags, source: source)
                if native { sleepMs(keyGapMs) }
                postRaw(kc, down: false, flags: digitFlags, source: source)
                if native { sleepMs(keyGapMs) }
            }
        }

        if native { postModifier(0x3A, flags: []) }                    // Left Alt up
        else      { postRaw(0x3A, down: false, flags: []) }
    }

    // Injects a character directly as a Unicode string — macOS apps receive the
    // correct glyph regardless of the current keyboard layout or input method.
    private static func postUnicode(_ char: Character) {
        let utf16 = Array(String(char).utf16)
        guard !utf16.isEmpty,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    // Events built from a .hidSystemState source update the *global* modifier state that
    // NSEvent.modifierFlags and CGEventSourceFlagsState report. With a nil source they only
    // carry flags on the event itself. The browser RDP client reads those event flags and is
    // happy either way; the native Windows App builds its scancode packets from the global
    // state, which is why synthetic Shift/Alt never reached it.
    private static let nativeSource = CGEventSource(stateID: .hidSystemState)

    // The Windows App needs a moment to notice a modifier change before the key that uses it
    // arrives — posting both back to back loses the modifier.
    private static let modifierSettleMs = 12
    private static let keyGapMs = 3

    private static func sleepMs(_ ms: Int) {
        Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
    }

    private static func postRaw(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags, source: CGEventSource? = nil) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private static func postKey(_ stroke: KeyStroke) {
        let needsShift  = stroke.flags.contains(.maskShift)
        let needsOption = stroke.flags.contains(.maskAlternate)

        // Send explicit modifier key events so RDP/browser sees a real Shift/Option
        // press rather than just a flag on the character event.
        if needsShift  { postRaw(0x38, down: true,  flags: .maskShift) }
        if needsOption { postRaw(0x3A, down: true,  flags: stroke.flags) }

        postRaw(stroke.keyCode, down: true,  flags: stroke.flags)
        postRaw(stroke.keyCode, down: false, flags: stroke.flags)

        if needsOption { postRaw(0x3A, down: false, flags: needsShift ? .maskShift : []) }
        if needsShift  { postRaw(0x38, down: false, flags: []) }
    }

    // Modifier changes on macOS are .flagsChanged events, not keyDown/keyUp — a keyDown on
    // 0x38/0x3A is ignored by clients that track the real modifier state. Posted from
    // nativeSource so the change lands in the global state, then given time to settle.
    // `flags` must carry the cumulative modifier state after this change, not just this key.
    private static func postModifier(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nativeSource, virtualKey: keyCode, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
        sleepMs(modifierSettleMs)
    }

    // Windows App variant. typeViaRdp only routes modifier-free keys here, so this posts a
    // bare key press; the flags/modifier handling stays for specialKeys and future callers.
    private static func postKeyNative(_ stroke: KeyStroke) {
        let needsShift  = stroke.flags.contains(.maskShift)
        let needsOption = stroke.flags.contains(.maskAlternate)

        if needsShift  { postModifier(0x38, flags: .maskShift) }
        if needsOption { postModifier(0x3A, flags: stroke.flags) }

        postRaw(stroke.keyCode, down: true,  flags: stroke.flags, source: nativeSource)
        sleepMs(keyGapMs)
        postRaw(stroke.keyCode, down: false, flags: stroke.flags, source: nativeSource)

        if needsOption { postModifier(0x3A, flags: needsShift ? .maskShift : []) }
        if needsShift  { postModifier(0x38, flags: []) }
    }
}
