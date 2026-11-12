import AppKit
import SwiftUI

protocol AgentActivationClickSafeRegion: AnyObject {}

/// The navigation and list panes contain safe, reversible controls, so they
/// opt into receiving the click that activates an inactive window. The
/// terminal pane deliberately does not use this host: its first activation
/// click must never be encoded as terminal input.
final class AgentInteractiveHostingView<Content: View>: NSHostingView<Content>,
    AgentActivationClickSafeRegion {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Centralizes first-responder transitions for the mixed AppKit/SwiftUI/Ghostty
/// workspace. Ghostty maintains its own logical focus bit, which must be
/// reconciled immediately after AppKit changes the actual responder.
final class AgentWorkspaceWindow: NSWindow {
    var onFirstResponderChanged: (() -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChanged?() }
        return accepted
    }

    override func sendEvent(_ event: NSEvent) {
        let targetsSafeRegion = contentView.map { contentView in
            let location = contentView.convert(event.locationInWindow, from: nil)
            return AgentFirstMousePolicy.targetsSafeRegion(
                startingAt: contentView.hitTest(location))
        } ?? false
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
    static func targetsSafeRegion(startingAt view: NSView?) -> Bool {
        var candidate = view
        while let view = candidate {
            if view is AgentActivationClickSafeRegion {
                return true
            }
            candidate = view.superview
        }
        return false
    }

    static func shouldPromoteWindow(
        eventType: NSEvent.EventType,
        windowIsKey: Bool,
        targetsSafeRegion: Bool
    ) -> Bool {
        eventType == .leftMouseDown && !windowIsKey && targetsSafeRegion
    }
}

enum AgentKeyEventRoutingPolicy {
    /// A field editor is an NSTextView temporarily owned by NSWindow, not the
    /// visible NSTextField. These events must stay in AppKit's responder chain
    /// even when a sheet or auxiliary panel temporarily leaves mainWindow nil.
    static func isTextEditingResponder(_ responder: NSResponder?) -> Bool {
        guard let textView = responder as? NSTextView else { return false }
        return textView.isFieldEditor || textView.isEditable
    }
}

/// Three-column workspace: navigation, agent list, and terminal detail.
final class AgentWorkspaceController: NSSplitViewController {

    private weak var detailVC: NSViewController?
    private let onFilterChanged: (String) -> Void
    private let onFocusTerminal: () -> Void
    private let canFocusTerminal: () -> Bool
    private let onShowAgentDetails: () -> Void
    private let canShowAgentDetails: () -> Bool

    init(
        navigationView: NSView,
        agentListView: NSView,
        detailViewController: NSViewController,
        onFilterChanged: @escaping (String) -> Void,
        onFocusTerminal: @escaping () -> Void,
        canFocusTerminal: @escaping () -> Bool,
        onShowAgentDetails: @escaping () -> Void,
        canShowAgentDetails: @escaping () -> Bool
    ) {
        self.detailVC = detailViewController
        self.onFilterChanged = onFilterChanged
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

    @objc private func filterChanged(_ sender: NSSearchField) { onFilterChanged(sender.stringValue) }
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
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .agentDetails, .focusTerminal, .agentFilter]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .toggleSidebar,
            .sidebarTrackingSeparator,
            .flexibleSpace,
            .space,
            .agentDetails,
            .focusTerminal,
            .agentFilter,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .agentFilter:
            // AppKit owns the search chrome: native metrics, field editor,
            // cancel/escape behavior. Typing filters the agent list live.
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter Agents"
            item.paletteLabel = "Filter Agents"
            item.toolTip = "Filter the agent list"
            item.searchField.placeholderString = "Filter Agents"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.sendsWholeSearchString = false
            item.searchField.target = self
            item.searchField.action = #selector(filterChanged(_:))
            return item
        case .focusTerminal:
            return makeItem(
                itemIdentifier,
                label: "Focus Terminal",
                symbol: "terminal",
                action: #selector(focusTerminal))
        case .agentDetails:
            return makeItem(
                itemIdentifier,
                label: "Agent Details",
                symbol: "info.circle",
                action: #selector(showAgentDetails),
                toolTip: "Show Model, Effort, and Context")
        default:
            return nil
        }
    }

    private func makeItem(
        _ identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        toolTip: String? = nil
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = toolTip ?? label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        // Bordered items let AppKit size the symbol and draw the standard
        // button, so every glyph matches instead of using its natural bounds.
        item.isBordered = true
        item.target = self
        item.action = action
        return item
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
    static let agentFilter = NSToolbarItem.Identifier("ClawddyFilterAgents")
    static let focusTerminal = NSToolbarItem.Identifier("ClawddyFocusTerminal")
    static let agentDetails = NSToolbarItem.Identifier("ClawddyAgentDetails")
}

/// Creates the workspace window with proper Liquid Glass sidebar styling.
func makeAgentWorkspaceWindow(
    controller: AgentWorkspaceController,
    appearance: NSAppearance?
) -> AgentWorkspaceWindow {
    let window = AgentWorkspaceWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.contentViewController = controller
    // The app-wide appearance is synchronized asynchronously to avoid an
    // AppKit launch mutex. Pin this window before its first frame so the
    // workspace never flashes in the system appearance.
    window.appearance = appearance
    window.title = "Clawddy"
    window.subtitle = "Agent Workspace"
    window.titleVisibility = .visible
    // AppKit owns the chrome: with fullSizeContentView + a full-height
    // sidebar item, the sidebar glass must run under the titlebar.
    window.titlebarAppearsTransparent = true
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
    // The standard sidebar-app toolbar; on macOS 26 this is what lets AppKit
    // render the sidebar as its native inset glass panel.
    window.toolbarStyle = .unified

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
        delegate.clawddy.restoreWorkspaceWindow(completionHandler: completionHandler)
    }
}
