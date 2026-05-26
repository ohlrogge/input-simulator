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

    static func type(_ text: String, delayMs: Int, token: CancellationToken) {
        flog("Typing started: \(text.count) chars, delay=\(delayMs)ms")
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
            } else if let stroke = charMap[char] {
                postKey(stroke)
                typed += 1
            } else {
                flog("Skipping unmapped character U+\(String(char.unicodeScalars.first!.value, radix: 16))")
                skipped += 1
            }

            if index % 50 == 49 {
                flog("Progress: \(index + 1)/\(text.count) characters")
            }

            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        }

        flog("Typing complete: \(typed) typed, \(skipped) skipped")
    }

    // Types a single character via the charMap — works in macOS apps.
    static func typeViaCharMap(_ char: Character) {
        if let keyCode = specialKeys[char] {
            postKey(KeyStroke(keyCode: keyCode, flags: []))
        } else if let stroke = charMap[char] {
            postKey(stroke)
        } else {
            flog("typeViaCharMap: no mapping for '\(char)'")
        }
    }

    // Types a single symbol via Windows Alt+numpad — works in Windows RDP.
    static func typeSymbol(_ char: Character) {
        guard let scalar = char.unicodeScalars.first, scalar.value <= 127 else {
            flog("typeSymbol: unsupported character '\(char)'")
            return
        }
        flog("typeSymbol: '\(char)' (ASCII \(scalar.value)) via Alt+numpad")
        postAltNumpad(ascii: scalar.value)
    }

    // Sends Alt+0XXX on the numpad — Windows interprets this as the ASCII character.
    private static func postAltNumpad(ascii: UInt32) {
        let numpadCodes: [UInt32: CGKeyCode] = [
            0: 0x52, 1: 0x53, 2: 0x54, 3: 0x55,
            4: 0x56, 5: 0x57, 6: 0x58, 7: 0x59,
            8: 0x5B, 9: 0x5C,
        ]
        let digits: [UInt32] = [0, ascii / 100, (ascii % 100) / 10, ascii % 10]

        postRaw(0x3A, down: true,  flags: .maskAlternate) // Left Alt down
        for d in digits {
            if let kc = numpadCodes[d] {
                postRaw(kc, down: true,  flags: .maskAlternate)
                postRaw(kc, down: false, flags: .maskAlternate)
            }
        }
        postRaw(0x3A, down: false, flags: []) // Left Alt up
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
}
