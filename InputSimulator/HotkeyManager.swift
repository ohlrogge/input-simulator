import Carbon
import os

private let log = Logger(subsystem: "com.niklas.inputsimulator", category: "hotkey")

class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Static storage so the C callback can reach the Swift closure
    private static var onTrigger: (() -> Void)?

    init(onTrigger: @escaping () -> Void) {
        HotkeyManager.onTrigger = onTrigger
        register()
    }

    private func register() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if hkID.id == 1 {
                    flog("Hotkey ⌃⌥⌘V fired")
                    HotkeyManager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &handlerRef
        )

        // ⌃⌥⌘V  (controlKey | optionKey | cmdKey)
        let id = EventHotKeyID(signature: 0x4953494D /* ISIM */, id: 1)
        let result = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey | cmdKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if result == noErr {
            flog("Hotkey ⌃⌥⌘V registered successfully")
        } else {
            flog("Failed to register hotkey ⌃⌥⌘V: OSStatus \(result)")
        }
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}
