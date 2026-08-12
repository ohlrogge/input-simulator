import AppKit
import ApplicationServices
import Carbon
import os

private let log = Logger(subsystem: "com.niklas.inputsimulator", category: "menubar")

private let kDelayKey      = "typingDelayMs"
private let kStartDelayKey = "startDelayMs"
private let kRdpModeKey    = "windowsRdpMode" // legacy, only read for migration
private let kTargetKey     = "targetSystem"

private struct Speed {
    let label: String
    let ms: Int
}

private let speeds: [Speed] = [
    Speed(label: "Slow (100 ms)",  ms: 100),
    Speed(label: "Normal (40 ms)", ms: 40),
    Speed(label: "Fast (15 ms)",   ms: 15),
]

private let startDelays: [Speed] = [
    Speed(label: "100 ms", ms: 100),
    Speed(label: "300 ms", ms: 300),
    Speed(label: "500 ms", ms: 500),
    Speed(label: "750 ms", ms: 750),
]

private let symbols: [(title: String, char: String)] = [
    ("[ bracket",   "["),
    ("] bracket",   "]"),
    ("{ brace",     "{"),
    ("} brace",     "}"),
    ("\\ backslash", "\\"),
    ("| pipe",      "|"),
    ("~ tilde",     "~"),
]


private func currentDelay() -> Int {
    let stored = UserDefaults.standard.integer(forKey: kDelayKey)
    // 0 is a valid custom value; only fall back to default when key was never set
    return UserDefaults.standard.object(forKey: kDelayKey) == nil ? 40 : max(0, stored)
}

private func currentStartDelay() -> Int {
    let stored = UserDefaults.standard.integer(forKey: kStartDelayKey)
    return stored > 0 ? stored : 300
}

private let targets: [TargetSystem] = [.macOS, .rdpBrowser]

private func currentTarget() -> TargetSystem {
    // Migration: installations that only ever saw the old boolean keep their setting.
    guard UserDefaults.standard.object(forKey: kTargetKey) != nil else {
        return UserDefaults.standard.bool(forKey: kRdpModeKey) ? .rdpBrowser : .macOS
    }
    return TargetSystem(rawValue: UserDefaults.standard.integer(forKey: kTargetKey)) ?? .macOS
}

class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hotkeyManager: HotkeyManager?
    private var speedItems: [NSMenuItem] = []
    private var customSpeedItem: NSMenuItem?
    private var startDelayItems: [NSMenuItem] = []
    private var targetItems: [NSMenuItem] = []

    private var currentToken: CancellationToken?
    private var escMonitor: Any?

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

        for s in symbols {
            let item = NSMenuItem(title: s.title, action: #selector(insertSymbol(_:)), keyEquivalent: "")
            item.representedObject = s.char
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let targetSubmenu = NSMenu()
        let activeTarget = currentTarget()
        for t in targets {
            let item = NSMenuItem(title: t.label, action: #selector(setTarget(_:)), keyEquivalent: "")
            item.target = self
            item.tag = t.rawValue
            item.state = t == activeTarget ? .on : .off
            targetSubmenu.addItem(item)
            targetItems.append(item)
        }
        let targetItem = NSMenuItem(title: "Zielsystem", action: nil, keyEquivalent: "")
        targetItem.submenu = targetSubmenu
        menu.addItem(targetItem)

        menu.addItem(.separator())

        let speedSubmenu = NSMenu()
        for speed in speeds {
            let item = NSMenuItem(title: speed.label, action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.tag = speed.ms
            speedSubmenu.addItem(item)
            speedItems.append(item)
        }
        speedSubmenu.addItem(.separator())
        let customItem = NSMenuItem(title: "Custom…", action: #selector(setCustomSpeed), keyEquivalent: "")
        customItem.target = self
        speedSubmenu.addItem(customItem)
        customSpeedItem = customItem
        updateSpeedCheckmarks()
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

        let statusMenuItem = NSMenuItem(title: "Status…", action: #selector(showStatus), keyEquivalent: "")
        statusMenuItem.target = self
        menu.addItem(statusMenuItem)


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
            KeyboardSimulator.type(text, delayMs: delay, token: token, target: currentTarget())
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
        // NSEvent global monitor sees all key events regardless of which app is focused —
        // more reliable than RegisterEventHotKey for plain ESC, which browsers intercept first.
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                flog("ESC detected — cancelling typing")
                self?.currentToken?.cancel()
                DispatchQueue.main.async { self?.finishTyping() }
            }
        }
    }

    private func unregisterEscape() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kTargetKey)
        targetItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
        flog("Zielsystem: \(currentTarget().label)")
    }

    @objc private func insertSymbol(_ sender: NSMenuItem) {
        guard let char = (sender.representedObject as? String)?.first else { return }
        let startDelay = currentStartDelay()
        let target = currentTarget()
        flog("Insert '\(char)' — target: \(target.label)")
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: Double(startDelay) / 1000.0)
            switch target {
            case .macOS:      KeyboardSimulator.typeViaCharMap(char)
            case .rdpBrowser: KeyboardSimulator.typeSymbol(char)
            }
        }
    }

    @objc private func showStatus() {
        let trusted = AXIsProcessTrusted()
        let clip = NSPasteboard.general.string(forType: .string)

        var lines: [String] = []
        lines.append(trusted ? "✅ Accessibility: granted" : "❌ Accessibility: NOT granted — relaunch after granting in System Settings → Privacy & Security → Accessibility")
        lines.append("🖥  Zielsystem: \(currentTarget().label)")
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

    private func updateSpeedCheckmarks() {
        let delay = currentDelay()
        let isPreset = speeds.contains { $0.ms == delay }
        speedItems.forEach { $0.state = $0.tag == delay ? .on : .off }
        if isPreset {
            customSpeedItem?.title = "Custom…"
            customSpeedItem?.state = .off
        } else {
            customSpeedItem?.title = "Custom (\(delay) ms)"
            customSpeedItem?.state = .on
        }
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kDelayKey)
        updateSpeedCheckmarks()
    }

    @objc private func setCustomSpeed() {
        let alert = NSAlert()
        alert.messageText = "Custom Typing Speed"
        alert.informativeText = "Delay between keystrokes in milliseconds (minimum 1 ms):"
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        input.stringValue = "\(currentDelay())"
        input.alignment = .right
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard let value = Int(raw), value >= 1 else { return }
        UserDefaults.standard.set(value, forKey: kDelayKey)
        flog("Custom typing speed set: \(value) ms")
        updateSpeedCheckmarks()
    }

    @objc private func setStartDelay(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: kStartDelayKey)
        startDelayItems.forEach { $0.state = $0.tag == sender.tag ? .on : .off }
    }
}
