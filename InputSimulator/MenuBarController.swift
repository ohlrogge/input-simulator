import AppKit
import Carbon

private let kDelayKey = "typingDelayMs"

private struct Speed {
    let label: String
    let ms: Int
}

private let speeds: [Speed] = [
    Speed(label: "Slow (100 ms)",   ms: 100),
    Speed(label: "Normal (40 ms)",  ms: 40),
    Speed(label: "Fast (15 ms)",    ms: 15),
]

private func currentDelay() -> Int {
    let stored = UserDefaults.standard.integer(forKey: kDelayKey)
    return stored > 0 ? stored : 40
}

class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotkeyManager: HotkeyManager?
    private var speedItems: [NSMenuItem] = []

    private var currentToken: CancellationToken?
    private var escHotKeyRef: EventHotKeyRef?
    private var escHandlerRef: EventHandlerRef?
    private static var onEscape: (() -> Void)?

    override init() {
        super.init()
        setupButton()
        setupMenu()
        hotkeyManager = HotkeyManager(onTrigger: { [weak self] in self?.pasteViaTyping() })
    }

    private func setupButton() {
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Input Simulator")
    }

    private func setupMenu() {
        let menu = NSMenu()

        let pasteItem = NSMenuItem(title: "Paste via Typing  ⌃⌥⌘V", action: #selector(pasteViaTyping), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        let speedSubmenu = NSMenu()
        let delay = currentDelay()
        for speed in speeds {
            let item = NSMenuItem(title: speed.label, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = speed.ms
            item.state = speed.ms == delay ? .on : .off
            speedSubmenu.addItem(item)
            speedItems.append(item)
        }
        let speedItem = NSMenuItem(title: "Typing Speed", action: nil, keyEquivalent: "")
        speedItem.submenu = speedSubmenu
        menu.addItem(speedItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func pasteViaTyping() {
        guard currentToken == nil else { return } // already typing
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        let delay = currentDelay()

        let token = CancellationToken()
        currentToken = token
        registerEscape()

        statusItem.button?.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "Typing… (ESC to cancel)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            KeyboardSimulator.type(text, delayMs: delay, token: token)
            DispatchQueue.main.async {
                self?.finishTyping()
            }
        }
    }

    private func finishTyping() {
        unregisterEscape()
        currentToken = nil
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Input Simulator")
    }

    private func registerEscape() {
        MenuBarController.onEscape = { [weak self] in
            self?.currentToken?.cancel()
            self?.finishTyping()
        }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                  EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hkID)
                if hkID.id == 2 { MenuBarController.onEscape?() }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &escHandlerRef
        )

        let id = EventHotKeyID(signature: 0x49534543 /* ISEC */, id: 2)
        RegisterEventHotKey(UInt32(kVK_Escape), 0, id, GetApplicationEventTarget(), 0, &escHotKeyRef)
    }

    private func unregisterEscape() {
        if let ref = escHotKeyRef { UnregisterEventHotKey(ref); escHotKeyRef = nil }
        if let ref = escHandlerRef { RemoveEventHandler(ref); escHandlerRef = nil }
        MenuBarController.onEscape = nil
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kDelayKey)
        speedItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }
}
