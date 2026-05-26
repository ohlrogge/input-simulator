import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        PermissionChecker.checkAndRequest()
        menuBarController = MenuBarController()
    }
}
