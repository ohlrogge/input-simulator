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

    private static func postKey(_ stroke: KeyStroke) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: stroke.keyCode, keyDown: false)
        else {
            flog("Failed to create CGEvent for keyCode \(stroke.keyCode)")
            return
        }
        down.flags = stroke.flags
        up.flags   = stroke.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
