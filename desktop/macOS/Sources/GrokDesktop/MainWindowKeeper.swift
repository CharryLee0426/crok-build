import AppKit

/// The main window's close button hides the window instead of closing it, as a Mac app's window
/// usually does: the app keeps running in the background, and its tasks, terminals and browser
/// pages with it. The Dock icon, the Window menu or a command for the window brings it back as it
/// was left. Quit is ⌘Q.
@MainActor
final class MainWindowKeeper: NSObject {
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    /// The close button was pressed in full screen: the window hides once it has left its Space.
    private var hidesAfterFullScreen = false

    func keep(_ window: NSWindow) {
        guard window !== self.window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        hidesAfterFullScreen = false
        claimCloseButton()
        // AppKit can build the title bar's buttons again when the window enters or leaves full screen.
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated { self?.windowChanged(notification.name) }
            }
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// The close button's action.
    @objc func hide(_ sender: Any?) {
        guard let window else { return }
        // Ordered out in full screen, the window would leave its Space behind, empty.
        if window.styleMask.contains(.fullScreen) {
            hidesAfterFullScreen = true
            window.toggleFullScreen(nil)
        } else {
            window.orderOut(nil)
        }
    }

    /// Brings the window back when its close button hid it or it is in the Dock. Returns whether it
    /// was off screen.
    @discardableResult
    func show() -> Bool {
        guard let window, !window.isVisible || window.isMiniaturized else { return false }
        hidesAfterFullScreen = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    private func windowChanged(_ name: Notification.Name) {
        claimCloseButton()
        if name == NSWindow.didExitFullScreenNotification, hidesAfterFullScreen {
            hidesAfterFullScreen = false
            window?.orderOut(nil)
        }
    }

    private func claimCloseButton() {
        guard let button = window?.standardWindowButton(.closeButton), button.action != #selector(hide(_:)) else { return }
        button.target = self
        button.action = #selector(hide(_:))
    }
}
