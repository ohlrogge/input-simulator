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
    // Dead keys (` ´ ^ ~ ¨ on QWERTZ) emit nothing on their own — they wait for the next
    // character to combine with. Posting them as key codes therefore reorders the output.
    let isDead: Bool
}

// A key is dead when translating it *without* kUCKeyTranslateNoDeadKeysMask yields no
// characters and leaves a pending dead-key state.
private func isDeadKey(_ layout: UnsafePointer<UCKeyboardLayout>, _ keyCode: UInt16,
                       _ modState: UInt32, _ kbType: UInt32) -> Bool {
    var deadKeyState: UInt32 = 0
    var chars = [UniChar](repeating: 0, count: 4)
    var charCount = 0
    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), modState, kbType,
                                0, &deadKeyState, chars.count, &charCount, &chars)
    return status == noErr && charCount == 0 && deadKeyState != 0
}

// Which system receives the keystrokes. Raw values are persisted in UserDefaults.
// The native Windows App is served by .macOS: with its connection set to Unicode keyboard
// mode it forwards Unicode key events verbatim. See CLAUDE.md.
enum TargetSystem: Int {
    case macOS      = 0 // Unicode string injection — macOS apps and the Windows App
    case rdpBrowser = 1 // RDP client running inside a browser (FortiClient)

    var label: String {
        switch self {
        case .macOS:      return "macOS / Windows App"
        case .rdpBrowser: return "RDP im Browser"
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
                map[char] = KeyStroke(keyCode: CGKeyCode(keyCode), flags: flags,
                                      isDead: isDeadKey(layout, keyCode, modState, kbType))
            }
        }
    }

    let deadCount = map.values.filter(\.isDead).count
    flog("Character map built: \(map.count) entries, \(deadCount) of them dead keys")
    return map
}

enum KeyboardSimulator {
    private static let specialKeys: [Character: CGKeyCode] = [
        "\n": 0x24, // Return
        "\r": 0x24, // Return
        "\t": 0x30, // Tab
    ]

    private static let charMap: [Character: KeyStroke] = buildCharacterMap()

    private static let breatherEveryChars = 250
    private static let breatherMs = 120

    // A CGEvent keyDown must be followed by a keyUp far enough apart for the receiver to see
    // a real press. Zero-length presses survive locally but get coalesced away under load.
    private static let keyHoldMs = 4

    // Counts events CGEvent(...) refused to create — without this the character just
    // vanishes silently, which is indistinguishable from the remote dropping it.
    private static var failedEvents = 0

    // Must be called once on the main thread before any typing begins.
    // TIS APIs are main-thread-only; this forces charMap to initialize there.
    static func warmUp() {
        assert(Thread.isMainThread)
        _ = charMap
        flog("KeyboardSimulator warmed up: \(charMap.count) characters mapped")
    }

    static func type(_ text: String, delayMs: Int, token: CancellationToken,
                     target: TargetSystem = .macOS, chunkSize: Int = 1) {
        flog("Typing started: \(text.count) chars, delay=\(delayMs)ms, target=\(target.label), chunk=\(chunkSize)")
        failedEvents = 0

        // Only the Unicode path can batch: the RDP browser path has to post one real key
        // code per character, which is exactly what that client reads.
        if target == .macOS && chunkSize > 1 {
            typeChunked(text, delayMs: delayMs, token: token, chunkSize: chunkSize)
            return
        }

        var typed = 0
        var skipped = 0

        for (index, char) in text.enumerated() {
            guard !token.isCancelled else {
                flog("Typing cancelled at character \(index)/\(text.count)")
                return
            }
            if let keyCode = specialKeys[char] {
                postKey(KeyStroke(keyCode: keyCode, flags: [], isDead: false))
                typed += 1
            } else {
                switch target {
                case .macOS:
                    // Send the Unicode string directly — works for all characters including
                    // Umlauts, regardless of the active keyboard layout.
                    postUnicode(char)
                    typed += 1
                case .rdpBrowser:
                    if typeViaRdp(char) { typed += 1 } else { skipped += 1 }
                }
            }

            if index % 50 == 49 {
                flog("Progress: \(index + 1)/\(text.count) characters")
            }

            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)

            // Long pastes outrun the receiver: the RDP client's input queue and the remote
            // Windows input buffer fill up after a few thousand keystrokes, after which
            // characters get dropped or arrive out of order. A regular breather lets both
            // drain. Cheap insurance — costs ~0.5 s per 1000 characters.
            if index % breatherEveryChars == breatherEveryChars - 1 {
                flog("Breather after \(index + 1) characters")
                Thread.sleep(forTimeInterval: Double(breatherMs) / 1000.0)
            }
        }

        flog("Typing complete: \(typed) typed, \(skipped) skipped, \(failedEvents) events failed to post")
    }

    // Posts up to `chunkSize` characters in a single Unicode key event — CGEvent's unicode
    // string is not limited to one character. That cuts the event count by the chunk factor,
    // which is the lever that matters when the receiver rather than the Mac is the bottleneck:
    // the RDP client and the remote input buffer see a handful of text events instead of
    // thousands of keystrokes. Return and Tab still go out as real key presses — they are key
    // codes, not text — and flush the pending chunk so the order is preserved.
    private static func typeChunked(_ text: String, delayMs: Int, token: CancellationToken, chunkSize: Int) {
        var typed = 0
        var sinceBreather = 0
        var chunk: [Character] = []
        chunk.reserveCapacity(chunkSize)

        func pause() {
            Thread.sleep(forTimeInterval: Double(delayMs) / 1000.0)
            if sinceBreather >= breatherEveryChars {
                flog("Breather after \(typed) characters")
                Thread.sleep(forTimeInterval: Double(breatherMs) / 1000.0)
                sinceBreather = 0
            }
        }

        func flushChunk() {
            guard !chunk.isEmpty else { return }
            postUnicodeString(String(chunk))
            typed += chunk.count
            sinceBreather += chunk.count
            chunk.removeAll(keepingCapacity: true)
            pause()
        }

        for char in text {
            guard !token.isCancelled else {
                flog("Typing cancelled at character \(typed)/\(text.count)")
                return
            }
            if let keyCode = specialKeys[char] {
                flushChunk()
                postKey(KeyStroke(keyCode: keyCode, flags: [], isDead: false))
                typed += 1
                sinceBreather += 1
                pause()
            } else {
                chunk.append(char)
                if chunk.count >= chunkSize { flushChunk() }
            }
        }
        flushChunk()

        flog("Typing complete: \(typed) typed, 0 skipped, \(failedEvents) events failed to post")
    }

    // Types one character into an RDP session. Prefers key codes from charMap (RDP reads
    // virtual key codes, not the Unicode string). Exception: chars that require the
    // Option/Alt modifier (e.g. [ ] { } \ | on QWERTZ) go through Alt+numpad instead —
    // browsers intercept Option+key before the HTML5 RDP client sees it, and on the Windows
    // side those characters sit on entirely different keys anyway. Alt+numpad is forwarded
    // correctly by both clients and is layout-independent on Windows.
    //
    // Dead keys (` ´ ^ ~ ¨ on QWERTZ) take the same detour. They emit nothing until the next
    // character arrives to combine with, so as key codes they reorder the output: ```{ came
    // out as ``{` and a trailing ``` lost its third backtick.
    //
    // Returns false if the character has no usable route.
    private static func typeViaRdp(_ char: Character) -> Bool {
        let scalar = char.unicodeScalars.first
        if let stroke = charMap[char] {
            if stroke.isDead || stroke.flags.contains(.maskAlternate),
               let scalar, scalar.value >= 32 && scalar.value <= 127 {
                postAltNumpad(ascii: scalar.value)
            } else {
                postKey(stroke)
            }
            return true
        }
        if let scalar, scalar.value >= 32 && scalar.value <= 255 {
            postAltNumpad(ascii: scalar.value)
            return true
        }
        flog("Skipping unmapped character U+\(String(scalar?.value ?? 0, radix: 16))")
        return false
    }

    // Types a single character via unicode string injection — works in macOS apps.
    static func typeViaCharMap(_ char: Character) {
        if let keyCode = specialKeys[char] {
            postKey(KeyStroke(keyCode: keyCode, flags: [], isDead: false))
        } else {
            postUnicode(char)
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

    private static let numpadCodes: [UInt32: CGKeyCode] = [
        0: 0x52, 1: 0x53, 2: 0x54, 3: 0x55,
        4: 0x56, 5: 0x57, 6: 0x58, 7: 0x59,
        8: 0x5B, 9: 0x5C,
    ]

    // Sends Alt+XXX on the numpad without leading zeros — Windows 11 accepts OEM short-form.
    // Verified on Windows 11 Western locale; saves 1-2 numpad events per character.
    private static func postAltNumpad(ascii: UInt32) {
        var n = ascii
        var digits: [UInt32] = []
        repeat { digits.insert(n % 10, at: 0); n /= 10 } while n > 0

        postRaw(0x3A, down: true,  flags: .maskAlternate) // Left Alt down
        for d in digits {
            if let kc = numpadCodes[d] {
                postRaw(kc, down: true,  flags: .maskAlternate)
                postRaw(kc, down: false, flags: .maskAlternate)
            }
        }
        postRaw(0x3A, down: false, flags: []) // Left Alt up
    }

    // Injects a character directly as a Unicode string — macOS apps receive the
    // correct glyph regardless of the current keyboard layout or input method.
    private static func postUnicode(_ char: Character) {
        postUnicodeString(String(char))
    }

    private static func postUnicodeString(_ text: String) {
        let utf16 = Array(text.utf16)
        guard !utf16.isEmpty,
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        else {
            failedEvents += 1
            flog("Failed to create event for '\(text)' (\(failedEvents) so far)")
            return
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: Double(keyHoldMs) / 1000.0)
        up.post(tap: .cghidEventTap)
    }

    private static func postRaw(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else {
            failedEvents += 1
            flog("Failed to create event for keyCode \(keyCode) (\(failedEvents) so far)")
            return
        }
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
