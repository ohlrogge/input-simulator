import Carbon
import CoreGraphics
import Foundation

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
    var map: [Character: KeyStroke] = [:]

    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return map }

    let cfData = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(cfData) else { return map }
    let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

    // Try modifier combinations in preference order: prefer simpler modifiers.
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

    return map
}

enum KeyboardSimulator {
    private static let specialKeys: [Character: CGKeyCode] = [
        "\n": 0x24, // Return
        "\r": 0x24, // Return
        "\t": 0x30, // Tab
    ]

    private static let charMap: [Character: KeyStroke] = buildCharacterMap()

    static func type(_ text: String, delayMs: Int, token: CancellationToken) {
        for char in text {
            guard !token.isCancelled else { return }
            if let keyCode = specialKeys[char] {
                postKey(KeyStroke(keyCode: keyCode, flags: []))
            } else if let stroke = charMap[char] {
                postKey(stroke)
            }
            // Characters not found in the layout map are silently skipped.
            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        }
    }

    private static func postKey(_ stroke: KeyStroke) {
        let needsShift  = stroke.flags.contains(.maskShift)
        let needsOption = stroke.flags.contains(.maskAlternate)

        // Mirror real hardware: press modifier keys before the character key,
        // release them after. RDP reads the explicit key events, not just the flags.
        if needsShift  { postRaw(0x38, down: true,  flags: .maskShift) }
        if needsOption { postRaw(0x3A, down: true,  flags: stroke.flags) }

        postRaw(stroke.keyCode, down: true,  flags: stroke.flags)
        postRaw(stroke.keyCode, down: false, flags: stroke.flags)

        if needsOption { postRaw(0x3A, down: false, flags: needsShift ? .maskShift : []) }
        if needsShift  { postRaw(0x38, down: false, flags: []) }
    }

    private static func postRaw(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
