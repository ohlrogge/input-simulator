import Carbon

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
                if hkID.id == 1 { HotkeyManager.onTrigger?() }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &handlerRef
        )

        // ⌃⌥⌘V  (controlKey | optionKey | cmdKey)
        let id = EventHotKeyID(signature: 0x4953494D /* ISIM */, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey | cmdKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}
