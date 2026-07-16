import AppKit
import SwiftUI

/// The navigation and list panes contain safe, reversible controls, so they
/// opt into receiving the click that activates an inactive window. The
/// terminal pane deliberately does not use this host: its first activation
/// click must never be encoded as terminal input.
final class AgentInteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Centralizes first-responder transitions for the mixed AppKit/SwiftUI/Ghostty
/// workspace. Ghostty maintains its own logical focus bit, which must be
/// reconciled immediately after AppKit changes the actual responder.
final class AgentWorkspaceWindow: NSWindow {
    var onFirstResponderChanged: (() -> Void)?

    /// Regions whose controls are safe to operate with the click that makes
    /// this window key. The terminal is intentionally never registered: an
    /// activation click must not become terminal input.
    var firstMouseSafeViews: [NSView] = []

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChanged?() }
        return accepted
    }

    override func sendEvent(_ event: NSEvent) {
        let targetsSafeRegion = firstMouseSafeViews.contains { view in
            guard view.window === self, !view.isHiddenOrHasHiddenAncestor else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }
        if AgentFirstMousePolicy.shouldPromoteWindow(
            eventType: event.type,
            windowIsKey: isKeyWindow,
            targetsSafeRegion: targetsSafeRegion
        ) {
            // Promote before AppKit dispatches the original event. This avoids
            // target-dependent acceptsFirstMouse behavior inside SwiftUI/List
            // without synthesizing, reposting, or retrying the click.
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}

enum AgentFirstMousePolicy {
    static func shouldPromoteWindow(
        eventType: NSEvent.EventType,
        windowIsKey: Bool,
        targetsSafeRegion: Bool
    ) -> Bool {
        eventType == .leftMouseDown && !windowIsKey && targetsSafeRegion
    }
}

/// Three-column workspace: navigation, agent list, and terminal detail.
final class AgentWorkspaceController: NSSplitViewController {

    private weak var detailVC: NSViewController?
    private let onSearch: () -> Void
    private let onFocusTerminal: () -> Void
    private let canFocusTerminal: () -> Bool
    private let onShowAgentDetails: () -> Void
    private let canShowAgentDetails: () -> Bool

    init(
        navigationView: NSView,
        agentListView: NSView,
        detailViewController: NSViewController,
        onSearch: @escaping () -> Void,
        onFocusTerminal: @escaping () -> Void,
        canFocusTerminal: @escaping () -> Bool,
        onShowAgentDetails: @escaping () -> Void,
        canShowAgentDetails: @escaping () -> Bool
    ) {
        self.detailVC = detailViewController
        self.onSearch = onSearch
        self.onFocusTerminal = onFocusTerminal
        self.canFocusTerminal = canFocusTerminal
        self.onShowAgentDetails = onShowAgentDetails
        self.canShowAgentDetails = canShowAgentDetails
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: Self.wrap(navigationView))
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 210
        sidebarItem.maximumThickness = 320
        sidebarItem.allowsFullHeightLayout = true

        let listItem = NSSplitViewItem(viewController: Self.wrap(agentListView))
        listItem.canCollapse = true
        listItem.minimumThickness = 260
        listItem.maximumThickness = 420

        let detailItem = NSSplitViewItem(viewController: detailViewController)
        detailItem.minimumThickness = 400

        addSplitViewItem(sidebarItem)
        addSplitViewItem(listItem)
        addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "ClawddyAgentWorkspaceSplit"
        // Disable live-resize content redraw on the detail pane.
        // The terminal IOSurface layer recreates on every frame change, causing GPU stalls.
        // With .never, the existing content stretches during drag; layout() fires once at end.
        if let detailView = detailVC?.view {
            detailView.layerContentsRedrawPolicy = .never
        }
    }

    @objc private func showSearch() { onSearch() }
    @objc private func focusTerminal() { onFocusTerminal() }
    @objc private func showAgentDetails() { onShowAgentDetails() }

    private static func wrap(_ content: NSView) -> NSViewController {
        let controller = NSViewController()
        let wrapper = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: wrapper.topAnchor),
            content.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        controller.view = wrapper
        return controller
    }
}

// MARK: - Toolbar Delegate

extension AgentWorkspaceController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .agentSearch, .agentDetails, .focusTerminal]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .space,
            .agentSearch,
            .agentDetails,
            .focusTerminal,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .agentSearch:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Search Agents"
            item.paletteLabel = "Search Agents"
            item.toolTip = "Search Agents"
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search Agents")
            item.target = self
            item.action = #selector(showSearch)
            return item
        case .focusTerminal:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Focus Terminal"
            item.paletteLabel = "Focus Terminal"
            item.toolTip = "Focus Terminal"
            item.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "Focus Terminal")
            item.target = self
            item.action = #selector(focusTerminal)
            return item
        case .agentDetails:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Agent Details"
            item.paletteLabel = "Agent Details"
            item.toolTip = "Show Model, Effort, and Context"
            item.image = NSImage(
                systemSymbolName: "info.circle",
                accessibilityDescription: "Agent Details")
            item.target = self
            item.action = #selector(showAgentDetails)
            return item
        default:
            return nil
        }
    }
}

extension AgentWorkspaceController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .focusTerminal: return canFocusTerminal()
        case .agentDetails: return canShowAgentDetails()
        default: return true
        }
    }
}

private extension NSToolbarItem.Identifier {
    static let agentSearch = NSToolbarItem.Identifier("ClawddySearchAgents")
    static let focusTerminal = NSToolbarItem.Identifier("ClawddyFocusTerminal")
    static let agentDetails = NSToolbarItem.Identifier("ClawddyAgentDetails")
}

/// Creates the workspace window with proper Liquid Glass sidebar styling.
func makeAgentWorkspaceWindow(controller: AgentWorkspaceController) -> AgentWorkspaceWindow {
    let window = AgentWorkspaceWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    window.title = "Clawddy"
    window.subtitle = "Agent Workspace"
    window.titleVisibility = .visible
    window.titlebarAppearsTransparent = false
    window.contentMinSize = NSSize(width: 900, height: 480)
    window.isReleasedWhenClosed = false
    window.identifier = NSUserInterfaceItemIdentifier("ClawddyAgentWorkspace")
    window.isRestorable = true
    window.restorationClass = AgentWorkspaceRestoration.self
    window.autorecalculatesKeyViewLoop = true

    // Toolbar with sidebar tracking separator — must set delegate before assigning to window
    let toolbar = NSToolbar(identifier: "AgentWorkspaceToolbar")
    toolbar.delegate = controller
    toolbar.displayMode = .iconOnly
    window.toolbar = toolbar
    window.toolbarStyle = .unifiedCompact

    if !window.setFrameUsingName("AgentWorkspace") {
        window.center()
    }
    window.setFrameAutosaveName("AgentWorkspace")
    return window
}

final class AgentWorkspaceRestoration: NSObject, NSWindowRestoration {
    static func restoreWindow(
        withIdentifier identifier: NSUserInterfaceItemIdentifier,
        state: NSCoder,
        completionHandler: @escaping (NSWindow?, Error?) -> Void
    ) {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            let error = NSError(
                domain: "com.mitchellh.ghostty.clawddy.restoration",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The agent workspace is not ready."])
            completionHandler(nil, error)
            return
        }
        delegate.restoreAgentWorkspaceWindow(completionHandler: completionHandler)
    }
}
