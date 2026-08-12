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
    // `native` selects the Windows App variant, which sends modifiers as .flagsChanged events.
    // Returns false if the character has no usable route.
    private static func typeViaRdp(_ char: Character, native: Bool) -> Bool {
        let scalar = char.unicodeScalars.first
        if let stroke = charMap[char] {
            if stroke.flags.contains(.maskAlternate),
               let scalar, scalar.value >= 32 && scalar.value <= 127 {
                postAltNumpad(ascii: scalar.value, native: native)
            } else if native {
                postKeyNative(stroke)
            } else {
                postKey(stroke)
            }
            return true
        }
        if let scalar, scalar.value >= 32 && scalar.value <= 255 {
            postAltNumpad(ascii: scalar.value, native: native)
            return true
        }
        flog("Skipping unmapped character U+\(String(scalar?.value ?? 0, radix: 16))")
        return false
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
    private static func postAltNumpad(ascii: UInt32, native: Bool) {
        let numpadCodes: [UInt32: CGKeyCode] = [
            0: 0x52, 1: 0x53, 2: 0x54, 3: 0x55,
            4: 0x56, 5: 0x57, 6: 0x58, 7: 0x59,
            8: 0x5B, 9: 0x5C,
        ]
        var n = ascii
        var digits: [UInt32] = []
        repeat { digits.insert(n % 10, at: 0); n /= 10 } while n > 0

        let digitFlags: CGEventFlags = native ? [.maskAlternate, .maskNumericPad] : .maskAlternate

        if native { postModifier(0x3A, flags: .maskAlternate) }        // Left Alt down
        else      { postRaw(0x3A, down: true, flags: .maskAlternate) }

        for d in digits {
            if let kc = numpadCodes[d] {
                postRaw(kc, down: true,  flags: digitFlags)
                postRaw(kc, down: false, flags: digitFlags)
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

    private static func postRaw(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
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

    // Modifier changes on macOS are .flagsChanged events, not keyDown/keyUp. The native
    // Windows App tracks the modifier state from those and ignores a keyDown on 0x38/0x3A,
    // which is why Shift and Alt were swallowed there (= arrived as 0, ( as 8, # as 35).
    // `flags` must carry the cumulative modifier state after this change, not just this key.
    private static func postModifier(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else { return }
        event.type = .flagsChanged
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    // Same shape as postKey, but modifiers go out as real .flagsChanged events so the
    // native Windows App picks them up.
    private static func postKeyNative(_ stroke: KeyStroke) {
        let needsShift  = stroke.flags.contains(.maskShift)
        let needsOption = stroke.flags.contains(.maskAlternate)

        if needsShift  { postModifier(0x38, flags: .maskShift) }
        if needsOption { postModifier(0x3A, flags: stroke.flags) }

        postRaw(stroke.keyCode, down: true,  flags: stroke.flags)
        postRaw(stroke.keyCode, down: false, flags: stroke.flags)

        if needsOption { postModifier(0x3A, flags: needsShift ? .maskShift : []) }
        if needsShift  { postModifier(0x38, flags: []) }
    }
}
