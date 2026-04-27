import AppKit
import SwiftUI

/// Container that refuses first responder so the sidebar never steals
/// focus from the terminal surface. Mouse events still pass through normally.
private final class NonFocusableContainer: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The main workspace window — NSSplitViewController with sidebar + detail.
/// Sidebar shows project/task/agent tree, detail shows the active terminal.
final class AgentWorkspaceController: NSSplitViewController {

    private weak var detailVC: NSViewController?

    init(sidebarView: NSView, detailViewController: NSViewController) {
        self.detailVC = detailViewController
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: {
            let vc = NSViewController()
            // Wrap in a non-focusable container so the sidebar VC never becomes
            // first responder. Arrow keys flow through to the terminal surface.
            let wrapper = NonFocusableContainer()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            sidebarView.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(sidebarView)
            NSLayoutConstraint.activate([
                sidebarView.topAnchor.constraint(equalTo: wrapper.topAnchor),
                sidebarView.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                sidebarView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                sidebarView.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            ])
            vc.view = wrapper
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

    override func viewDidLoad() {
        super.viewDidLoad()
        // Disable live-resize content redraw on the detail pane.
        // The terminal IOSurface layer recreates on every frame change, causing GPU stalls.
        // With .never, the existing content stretches during drag; layout() fires once at end.
        if let detailView = detailVC?.view {
            detailView.layerContentsRedrawPolicy = .duringViewResize
        }
    }
}

// MARK: - Toolbar Delegate

extension AgentWorkspaceController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        NSToolbarItem(itemIdentifier: itemIdentifier)
    }
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
    window.title = "Clawddy"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentMinSize = NSSize(width: 620, height: 400)
    window.isReleasedWhenClosed = false

    // Toolbar with sidebar tracking separator — must set delegate before assigning to window
    let toolbar = NSToolbar(identifier: "AgentWorkspaceToolbar")
    toolbar.delegate = controller
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact

    window.center()
    return window
}
