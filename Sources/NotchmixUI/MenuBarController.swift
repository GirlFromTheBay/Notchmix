import AppKit
import SwiftUI

/// The menu bar item and the panel it opens.
///
/// The panel is a system `NSPopover` anchored to an `NSStatusItem`. Using the
/// system's own popover rather than a hand-built window is what makes it
/// behave like the built-in menu bar modules: the open and close animation,
/// the Liquid Glass background (which follows the user's transparency and
/// tint settings), the shadow, the corner radius and the click-away dismissal
/// all come from AppKit, not from this app.
@MainActor
public final class MenuBarController: NSObject, NSPopoverDelegate {
    private let model: MixerModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let scrollMonitor = ScrollWheelMonitor()
    /// The app that had focus before the panel opened, to hand focus back.
    private var previousApp: NSRunningApplication?

    public init(model: MixerModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "slider.vertical.3", accessibilityDescription: "Notchmix")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(togglePanel)
            // Open on press, as the system's own items do, not on release.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        let host = NSHostingController(rootView: MixerPanel(model: model))
        // The popover follows the SwiftUI content's size, and animates to it
        // when rows come and go.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        hideAnchorArrow()
    }

    public var isPanelShown: Bool { popover.isShown }

    /// The window the system built for the open panel, for diagnostics.
    public var panelWindow: NSWindow? { popover.contentViewController?.view.window }

    @objc public func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        // A transient popover only notices clicks elsewhere, and only tracks
        // the pointer over its sliders, while its app is active.
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        panelWindow?.makeKey()
    }

    /// Menu bar modules hang from the bar without the pointed arrow an
    /// ordinary popover has. There is no public switch for it, so this asks
    /// only if the popover understands the request, and otherwise leaves the
    /// arrow in place.
    private func hideAnchorArrow() {
        guard popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) else { return }
        popover.setValue(true, forKey: "shouldHideAnchor")
    }

    // MARK: NSPopoverDelegate

    public func popoverWillShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
        model.panelDidAppear()
        let model = model
        scrollMonitor.start { delta in
            model.scrollHoveredSlider(by: delta)
        }
    }

    public func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        scrollMonitor.stop()
        model.panelDidDisappear()

        // Closing with Escape or the menu bar item leaves this windowless app
        // frontmost, with the app the user was in still dimmed. Give it back.
        if NSApp.isActive, let previousApp, !previousApp.isTerminated,
           previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate()
        }
        previousApp = nil
    }
}
