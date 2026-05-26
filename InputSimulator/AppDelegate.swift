import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        fclear()
        flog("App launched")
        PermissionChecker.checkAndRequest()
        KeyboardSimulator.warmUp()
        menuBarController = MenuBarController()
        flog("App ready")
    }
}
