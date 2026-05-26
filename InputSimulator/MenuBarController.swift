import AppKit
import ApplicationServices
import Carbon
import os

private let log = Logger(subsystem: "com.niklas.inputsimulator", category: "menubar")

private let kDelayKey     = "typingDelayMs"
private let kStartDelayKey = "startDelayMs"

private struct Speed {
    let label: String
    let ms: Int
}

private let speeds: [Speed] = [
    Speed(label: "Slow (100 ms)",   ms: 100),
    Speed(label: "Normal (40 ms)",  ms: 40),
    Speed(label: "Fast (15 ms)",    ms: 15),
]

private let startDelays: [Speed] = [
    Speed(label: "100 ms", ms: 100),
    Speed(label: "300 ms", ms: 300),
    Speed(label: "500 ms", ms: 500),
    Speed(label: "750 ms", ms: 750),
]

private func currentDelay() -> Int {
    let stored = UserDefaults.standard.integer(forKey: kDelayKey)
    return stored > 0 ? stored : 40
}

private func currentStartDelay() -> Int {
    let stored = UserDefaults.standard.integer(forKey: kStartDelayKey)
    return stored > 0 ? stored : 300
}

class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotkeyManager: HotkeyManager?
    private var speedItems: [NSMenuItem] = []
    private var startDelayItems: [NSMenuItem] = []

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

        let startDelaySubmenu = NSMenu()
        let startDelay = currentStartDelay()
        for sd in startDelays {
            let item = NSMenuItem(title: sd.label, action: #selector(setStartDelay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = sd.ms
            item.state = sd.ms == startDelay ? .on : .off
            startDelaySubmenu.addItem(item)
            startDelayItems.append(item)
        }
        let startDelayItem = NSMenuItem(title: "Start Delay", action: nil, keyEquivalent: "")
        startDelayItem.submenu = startDelaySubmenu
        menu.addItem(startDelayItem)

        menu.addItem(.separator())

        let statusItem2 = NSMenuItem(title: "Status…", action: #selector(showStatus), keyEquivalent: "")
        statusItem2.target = self
        menu.addItem(statusItem2)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func pasteViaTyping() {
        guard currentToken == nil else {
            flog("Paste triggered but already typing — ignored")
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            flog("Paste triggered but clipboard is empty or non-text")
            return
        }
        let delay = currentDelay()
        let startDelay = currentStartDelay()
        flog("Paste triggered: \(text.count) chars, startDelay=\(startDelay)ms, typingDelay=\(delay)ms")

        let token = CancellationToken()
        currentToken = token
        registerEscape()

        statusItem.button?.image = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: "Typing… (ESC to cancel)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            flog("Start delay: sleeping \(startDelay)ms")
            Thread.sleep(forTimeInterval: Double(startDelay) / 1000.0)
            flog("Start delay done, handing off to KeyboardSimulator")
            KeyboardSimulator.type(text, delayMs: delay, token: token)
            DispatchQueue.main.async {
                self?.finishTyping()
            }
        }
    }

    private func finishTyping() {
        flog("Typing session ended, resetting state")
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

    @objc private func showStatus() {
        let trusted = AXIsProcessTrusted()
        let clip = NSPasteboard.general.string(forType: .string)

        var lines: [String] = []
        lines.append(trusted ? "✅ Accessibility: granted" : "❌ Accessibility: NOT granted — relaunch after granting in System Settings → Privacy & Security → Accessibility")
        if let text = clip {
            let preview = text.prefix(60).replacingOccurrences(of: "\n", with: "↵")
            lines.append("📋 Clipboard (\(text.count) chars): \"\(preview)\(text.count > 60 ? "…" : "")\"")
        } else {
            lines.append("📋 Clipboard: empty or non-text")
        }

        let alert = NSAlert()
        alert.messageText = "Input Simulator Status"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kDelayKey)
        speedItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }

    @objc private func setStartDelay(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kStartDelayKey)
        startDelayItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }
}
