import AppKit
import SwiftUI

final class SettingsController: NSWindowController {
    static let shared = SettingsController()

    private init() {
        let hostingController = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Clawddy Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(activate: Bool = true) {
        guard let window else { return }
        if activate {
            showWindow(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderBack(nil)
        }
    }
}
