import AppKit
import SwiftUI

final class SettingsController: NSWindowController {
    init(preferencesFile: URL, onSave: @escaping (AgentPreferences) -> Void) {
        let hostingController = NSHostingController(
            rootView: SettingsView(preferencesFile: preferencesFile, onSave: onSave))
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

    func show() {
        guard let window else { return }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
