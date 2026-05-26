import AppKit
import ApplicationServices

enum PermissionChecker {
    static func checkAndRequest() {
        guard !AXIsProcessTrusted() else { return }

        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            Input Simulator needs Accessibility access to simulate keystrokes.

            Click "Open Settings" to enable it under:
            Privacy & Security → Accessibility
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
        NSApplication.shared.terminate(nil)
    }
}
