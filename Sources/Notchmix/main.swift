import AppKit
import NotchmixUI

/// Notchmix lives entirely in the menu bar: no Dock icon, no windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let openedOnceKey = "HasOpenedPanelOnce"
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MenuBarController(model: MixerModel())
        menuBar = controller
        if !UserDefaults.standard.bool(forKey: Self.openedOnceKey) {
            UserDefaults.standard.set(true, forKey: Self.openedOnceKey)
            DispatchQueue.main.async {
                controller.showPanelIfNeeded()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBar?.showPanelIfNeeded()
        return false
    }
}

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
