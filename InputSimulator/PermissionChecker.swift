import ApplicationServices

enum PermissionChecker {
    static func checkAndRequest() {
        guard !AXIsProcessTrusted() else { return }
        // Let macOS show its native prompt and add the app to the Accessibility list.
        // The user must relaunch the app once after granting — standard macOS behaviour.
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(opts)
    }
}
