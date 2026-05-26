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

enum KeyboardSimulator {
    private static let specialKeys: [Character: CGKeyCode] = [
        "\n": 0x24, // Return
        "\r": 0x24, // Return
        "\t": 0x30, // Tab
    ]

    static func type(_ text: String, delayMs: Int, token: CancellationToken) {
        for char in text {
            guard !token.isCancelled else { return }
            if let keyCode = specialKeys[char] {
                postKey(keyCode)
            } else {
                postUnicode(char)
            }
            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
        }
    }

    private static func postKey(_ keyCode: CGKeyCode) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func postUnicode(_ char: Character) {
        let utf16 = Array(String(char).utf16)
        guard !utf16.isEmpty else { return }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else { return }

        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
