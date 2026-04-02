import AppKit
import SwiftUI

/// The main workspace window — NSSplitViewController with sidebar + detail.
/// Sidebar shows project/task/agent tree, detail shows the active terminal.
final class AgentWorkspaceController: NSSplitViewController {

    init(sidebarView: NSView, detailViewController: NSViewController) {
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: {
            let vc = NSViewController()
            vc.view = sidebarView
            return vc
        }())
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 220
        sidebarItem.maximumThickness = 350
        sidebarItem.allowsFullHeightLayout = true

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Creates the workspace window with proper Liquid Glass sidebar styling.
func makeAgentWorkspaceWindow(controller: AgentWorkspaceController) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    window.setFrameAutosaveName("AgentWorkspace")
    window.title = "Agents"
    window.titlebarAppearsTransparent = true
    window.contentMinSize = NSSize(width: 600, height: 400)
    window.isReleasedWhenClosed = false

    // Toolbar with sidebar tracking separator for native macOS sidebar appearance
    let toolbar = NSToolbar(identifier: "AgentWorkspaceToolbar")
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact

    window.center()
    return window
}
