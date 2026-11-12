import AppKit
import Combine
import SwiftUI
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentDetail")

/// Hosts each agent's Ghostty terminal in its own AgentTerminalHost (which
/// supplies the TerminalViewModel + TerminalViewDelegate contract Ghostty's
/// TerminalView requires). Surfaces live inside a SplitTree owned by the
/// host — never re-parented into custom plumbing — so the focus chain
/// (@FocusedValue → focusedSurfaceDidChange → focusedSurface didSet →
/// syncFocus → ghostty_surface_set_focus) runs unchanged.
///
/// All keys are UUID-based. Zero rekey on rename.
///
/// This controller is the only owner of agent surfaces. It reports each
/// surface's close, process exit and program status to the bridge, tagged
/// with the launch the surface was created for.
final class AgentDetailViewController: NSViewController {

    /// Everything one agent's terminal needs, created and destroyed together.
    private struct Pane {
        let host: AgentTerminalHost
        let container: TerminalViewContainer
        let surface: Ghostty.SurfaceView
        /// The launch the surface was created for.
        let generation: UUID?
        /// Report the surface to the bridge; cancelled with the pane.
        let observers: [AnyCancellable]
    }

    private weak var ghostty: Ghostty.App?
    private let bridge: AgentBridge

    private var panesByID: [UUID: Pane] = [:]
    /// The agent the pane presents: the header's agent.
    var activeID: UUID? { headerModel.agent?.id }

    private var placeholderView: NSView?
    private var headerHosting: NSHostingView<AgentDetailHeaderView>?
    private var headerModel = AgentDetailHeaderModel()

    private var keyObservers: [NSObjectProtocol] = []
    private var closeAlert: NSAlert?

    /// Activates an agent by id. Wired once by the workspace owner; the header
    /// invokes it with the currently displayed agent's id at click time, so a
    /// stale per-selection closure is impossible by construction.
    var onStartAgent: ((UUID) -> Void)? {
        didSet { headerModel.onStart = onStartAgent }
    }

    /// Starts a new session for an agent whose saved session is missing.
    /// Wired once, like `onStartAgent`.
    var onStartFresh: ((UUID) -> Void)? {
        didSet { headerModel.onStartFresh = onStartFresh }
    }

    init(ghostty: Ghostty.App, bridge: AgentBridge) {
        self.ghostty = ghostty
        self.bridge = bridge
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        for o in keyObservers { NotificationCenter.default.removeObserver(o) }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        let headerView = AgentInteractiveHostingView(
            rootView: AgentDetailHeaderView(model: headerModel))
        headerView.translatesAutoresizingMaskIntoConstraints = false
        headerView.setContentHuggingPriority(.required, for: .vertical)
        headerView.setContentCompressionResistancePriority(.required, for: .vertical)
        view.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        headerHosting = headerView

        let placeholder = AgentInteractiveHostingView(
            rootView: AgentPlaceholderView(model: headerModel))
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        placeholderView = placeholder
        headerModel.onFocusTerminal = { [weak self] in self?.focusTerminal() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installWindowKeyObserversIfNeeded()
    }

    private var terminalTopAnchor: NSLayoutYAxisAnchor {
        headerHosting!.bottomAnchor
    }

    /// Observe the workspace window's key transitions so the active host
    /// can re-run its focus invariant. Without this, focus goes stale when
    /// the user ⌘-Tabs away and back.
    private func installWindowKeyObserversIfNeeded() {
        guard keyObservers.isEmpty, let window = view.window else { return }
        let nc = NotificationCenter.default
        let onKey: (Notification) -> Void = { [weak self] _ in
            self?.activePane?.host.syncFocus()
        }
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: onKey))
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: onKey))
    }

    private var activePane: Pane? {
        guard let id = activeID else { return nil }
        return panesByID[id]
    }

    /// Reconcile Ghostty's logical focus after AppKit accepts any responder
    /// transition in the workspace window. This is required for field editors:
    /// the real first responder is an NSTextView owned by NSWindow, not the
    /// SwiftUI TextField that initiated editing.
    func workspaceFirstResponderDidChange() {
        activePane?.host.syncFocus()
    }

    /// Update the detail selection without launching work or stealing focus.
    func selectAgent(_ agent: AgentInstance, projectName: String) {
        if headerModel.agent?.id != agent.id {
            headerModel.showsAgentDetails = false
        }
        headerModel.agent = agent
        headerModel.projectName = projectName
        refreshPresentation()
        installWindowKeyObserversIfNeeded()
    }

    /// The one place presentation is computed. Invariants enforced here:
    /// only the active pane may be attached and hold logical focus; header
    /// and placeholder visibility are derived from whether that pane exists.
    /// Every pane or selection mutation funnels through this method.
    private func refreshPresentation() {
        for (id, pane) in panesByID where id != activeID {
            pane.host.focusedSurface = nil
            pane.container.removeFromSuperview()
        }
        let pane = activePane
        if let pane, let activeID { attach(pane, id: activeID) }
        let hasSurface = pane != nil
        if headerModel.hasSurface != hasSurface {
            headerModel.hasSurface = hasSurface
        }
        placeholderView?.isHidden = hasSurface
    }

    /// Show an existing agent's terminal or create a new one after an explicit action.
    @discardableResult
    func showOrSwitch(
        projectName: String,
        agent: AgentInstance,
        focusTerminal: Bool = true,
        select: Bool = true,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        let id = agent.id
        // First: detaches the previous container, drops the previous host's
        // logical focus, and resets header state — before the new surface
        // claims anything. Also sets the header's agent, which is activeID.
        if select {
            selectAgent(agent, projectName: projectName)
        }

        var isNew = false

        if panesByID[id] == nil {
            guard let ghostty else { fatalError("AgentDetailViewController used without ghostty") }
            guard let app = ghostty.app, let config = createConfig() else {
                // No pane was created; presentation already reflects that.
                return false
            }
            let surface = Ghostty.SurfaceView(app, baseConfig: config)
            let host = AgentTerminalHost()
            host.surfaceTree = SplitTree(view: surface)

            let container = TerminalViewContainer {
                TerminalView(ghostty: ghostty, viewModel: host, delegate: host)
            }
            container.translatesAutoresizingMaskIntoConstraints = false

            // Must stay in the creation path: selection never sets
            // hostingWindow, so a pane created with select: false and later
            // shown via selectAgent would keep a nil hostingWindow and
            // syncFocus could never grant focus.
            host.hostingWindow = view.window
            panesByID[id] = Pane(
                host: host,
                container: container,
                surface: surface,
                generation: agent.launchGeneration,
                observers: observeAgentSurface(
                    surface,
                    childExited: surface.$childExitedMessage.compactMap { $0 }.map { _ in },
                    agentID: id,
                    generation: agent.launchGeneration,
                    bridge: bridge))
            isNew = true
            logger.info("created host for agent \(id)")
        }

        if select, let pane = panesByID[id] {
            // Attach before moveFocus (the pane may not have existed when
            // selectAgent refreshed): makeFirstResponder needs the view in a
            // window; don't lean on moveFocus's backoff to paper over it.
            refreshPresentation()
            // The window can change between creation and show (rare);
            // re-anchor BEFORE focusedSurface — its didSet runs syncFocus,
            // which reads hostingWindow.isKeyWindow.
            pane.host.hostingWindow = view.window
            // Logical selection before AppKit focus: the responder-change
            // callback must see this surface as selected to compute
            // focused == true.
            pane.host.focusedSurface = pane.surface
            // Canonical focus move. Pairs resignFirstResponder on the
            // previous focused surface.
            if focusTerminal {
                Ghostty.moveFocus(to: pane.surface)
            }
        }

        installWindowKeyObserversIfNeeded()

        return isNew
    }

    /// Present a pane whose asynchronous preparation just finished. Authority
    /// to attach or focus is re-derived from the pane this controller presents
    /// now, not from the activation that started the launch, so a selection
    /// change during preparation cannot steal focus. The pane is still created
    /// when it is no longer selected; it is simply retained for the next
    /// selection instead of replacing the current one.
    @discardableResult
    func presentPreparedSurface(
        projectName: String,
        agent: AgentInstance,
        createConfig: () -> Ghostty.SurfaceConfiguration?
    ) -> Bool {
        let window = view.window
        let presentation = AgentLaunchPresentationPolicy.decide(
            agentID: agent.id,
            selectedAgentID: activeID,
            windowIsVisible: window?.isVisible ?? false,
            windowIsMiniaturized: window?.isMiniaturized ?? false)
        return showOrSwitch(
            projectName: projectName,
            agent: agent,
            focusTerminal: presentation.focusesTerminal,
            select: presentation.presentsPane,
            createConfig: createConfig)
    }

    func focusTerminal() {
        guard let surface = activePane?.surface else { return }
        Ghostty.moveFocus(to: surface)
    }

    func showAgentDetails() {
        guard headerModel.agent != nil else { return }
        headerModel.showsAgentDetails = true
    }

    /// Asks before closing an agent terminal whose process is still running,
    /// in the words and form of Ghostty's terminal windows
    /// (`BaseTerminalController.closeSurface`): one sheet at a time, and with
    /// no window to ask in, the close goes ahead.
    func confirmClose(id: UUID, then close: @escaping @MainActor () -> Void) {
        guard closeAlert == nil, panesByID[id] != nil else { return }
        guard let window = view.window else {
            close()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Close Terminal?"
        alert.informativeText = "The terminal still has a running process. If you close the terminal the process will be killed."
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        closeAlert = alert
        Task {
            let response = await alert.beginSheetModal(for: window)
            // Keeps focus where it was under Stage Manager (Ghostty #8336).
            alert.window.orderOut(nil)
            closeAlert = nil
            if response == .alertFirstButtonReturn { close() }
        }
    }

    func removeSurface(id: UUID) {
        logger.info("removeSurface \(id)")
        guard let pane = panesByID.removeValue(forKey: id) else { return }
        pane.observers.forEach { $0.cancel() }
        pane.host.focusedSurface = nil
        pane.container.removeFromSuperview()
        refreshPresentation()
    }

    func showPlaceholder() {
        headerModel.agent = nil
        headerModel.showsAgentDetails = false
        refreshPresentation()
    }

    func hasSurface(id: UUID) -> Bool { panesByID[id] != nil }

    var hasActiveSurface: Bool { activePane != nil }

    private func attach(_ pane: Pane, id: UUID) {
        let container = pane.container
        guard container.superview == nil else { return }
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: terminalTopAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // Ghostty shows a process's exit, the only sign of an exit that
        // leaves the terminal open, only on a surface in a window. A detached
        // terminal has none, so an exit it missed is reported once it is back.
        guard pane.surface.processExited else { return }
        let generation = pane.generation
        // After this presentation pass, which the close changes.
        Task { @MainActor [bridge] in
            bridge.surfaceClosed(id: id, generation: generation, processAlive: false)
        }
    }

    /// Match the terminal canvas to Ghostty's theme: the layer takes the
    /// terminal background color and the placeholder's color scheme follows
    /// it. The header itself deliberately keeps the window-chrome color.
    func setBackgroundColor(_ color: NSColor) {
        headerModel.canvasColorScheme = AgentCanvasAppearancePolicy.colorScheme(
            for: color)
        view.layer?.backgroundColor = color.cgColor
    }
}

// MARK: - Header

@Observable
class AgentDetailHeaderModel {
    /// The agent the pane presents, or nil for the placeholder.
    var agent: AgentInstance?
    var projectName: String = ""
    var hasSurface: Bool = false
    var showsAgentDetails: Bool = false
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    var canvasColorScheme: ColorScheme = .dark
    @ObservationIgnored var onStart: ((UUID) -> Void)?
    @ObservationIgnored var onStartFresh: ((UUID) -> Void)?
    @ObservationIgnored var onFocusTerminal: (() -> Void)?
}

private struct AgentDetailHeaderView: View {
    var model: AgentDetailHeaderModel

    var body: some View {
        @Bindable var bindableModel = model
        VStack(spacing: 0) {
            if let agent = model.agent {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Label(agent.provider.displayName, systemImage: agent.provider.symbolName)
                            Text("·")
                            Text(model.projectName)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 16)

                    HStack(spacing: 5) {
                        Image(systemName: agent.displayState.iconName ?? "circle")
                            .foregroundStyle(agent.displayState.color)
                        Text(agent.displayState.label)
                            .foregroundStyle(.secondary)
                    }
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(agent.displayState.color.opacity(0.1), in: Capsule())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Agent status")
                        .accessibilityValue(agent.displayState.label)
                        .accessibilityAddTraits(.updatesFrequently)

                    if model.hasSurface && agent.processState != .exited {
                        Button("Focus Terminal", systemImage: "terminal") {
                            model.onFocusTerminal?()
                        }
                        .buttonStyle(.bordered)
                        .accessibilitySortPriority(1)
                    } else {
                        Button {
                            // A missing or unreadable session can only be
                            // replaced; a restart would fail on it again.
                            if agent.canOnlyStartFresh {
                                model.onStartFresh?(agent.id)
                            } else {
                                model.onStart?(agent.id)
                            }
                        } label: {
                            if agent.isStarting {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Starting…")
                                }
                            } else {
                                Label(primaryActionTitle(for: agent), systemImage: "play.fill")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(agent.isStarting)
                        .accessibilitySortPriority(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 7)
                .padding(.bottom, 5)

                AgentMetadataSummaryButton(
                    agent: agent,
                    showsDetails: $bindableModel.showsAgentDetails)
                    .accessibilitySortPriority(2)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            } else {
                Color.clear.frame(height: 52)
            }
        }
        .frame(maxWidth: .infinity)
        .background(model.backgroundColor)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func primaryActionTitle(for agent: AgentInstance) -> String {
        if agent.canOnlyStartFresh { return "Start Fresh" }
        if agent.interactionState == .authentication { return "Open Terminal to Sign In" }
        if agent.surfaceState == .failed { return "Retry" }
        if agent.processState == .exited { return "Restart" }
        return "Start"
    }
}

// MARK: - Placeholder

private struct PlaceholderIconBox: View {
    let systemName: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(color.opacity(0.09))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
            Image(systemName: systemName)
                .font(.system(size: 29, weight: .medium))
                .foregroundStyle(color)
        }
        .frame(width: 68, height: 68)
    }
}

private struct AgentPlaceholderView: View {
    var model: AgentDetailHeaderModel

    var body: some View {
        VStack(spacing: 0) {
            if let agent = model.agent {
                PlaceholderIconBox(
                    systemName: placeholderIcon(for: agent),
                    color: placeholderColor(for: agent))
                .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
                .padding(.bottom, 20)

                Text(agent.name)
                    .font(.title2.weight(.semibold))
                    .tracking(-0.25)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Label(agent.provider.displayName, systemImage: agent.provider.symbolName)
                    Text("·")
                    Text(model.projectName)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 5)

                Label(placeholderTitle(for: agent), systemImage: agent.displayState.iconName ?? "circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(placeholderColor(for: agent))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(placeholderColor(for: agent).opacity(0.09), in: Capsule())
                    .padding(.top, 16)

                Text(placeholderMessage(for: agent))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 11)

                AgentMetadataCompactLine(agent: agent)
                    .padding(.top, 10)

                Button {
                    if agent.canOnlyStartFresh {
                        model.onStartFresh?(agent.id)
                    } else {
                        model.onStart?(agent.id)
                    }
                } label: {
                    if agent.isStarting {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text("Starting Agent…")
                        }
                    } else {
                        Text(placeholderButtonTitle(for: agent))
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(agent.isStarting)
                .padding(.top, 18)
            } else {
                PlaceholderIconBox(systemName: "sidebar.left", color: .secondary)
                    .padding(.bottom, 20)

                Text("Select an Agent")
                    .font(.title2.weight(.semibold))
                    .tracking(-0.25)

                Text("Choose an agent in the sidebar to view its status and terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .padding(.top, 8)
            }
        }
        .frame(minWidth: 380, maxWidth: 520)
        .padding(48)
        // The canvas follows the terminal theme, which can intentionally
        // differ from the macOS appearance used by the surrounding workspace.
        .environment(\.colorScheme, model.canvasColorScheme)
        .accessibilityElement(children: .contain)
    }

    private func placeholderIcon(for agent: AgentInstance) -> String {
        if agent.surfaceState == .failed || agent.runtimeErrorMessage != nil {
            return "exclamationmark.triangle"
        }
        if agent.interactionState == .authentication {
            return "person.crop.circle.badge.exclamationmark"
        }
        return "terminal"
    }

    private func placeholderColor(for agent: AgentInstance) -> Color {
        if agent.surfaceState == .failed || agent.runtimeErrorMessage != nil { return .red }
        if agent.interactionState == .authentication { return .orange }
        return .secondary
    }

    private func placeholderTitle(for agent: AgentInstance) -> String {
        if agent.surfaceState == .failed { return "Couldn't Start Agent" }
        if agent.runtimeErrorMessage != nil { return "Agent Needs Attention" }
        if agent.interactionState == .authentication {
            return "Sign In to \(agent.provider.displayName)"
        }
        return "Ready to Start"
    }

    private func placeholderMessage(for agent: AgentInstance) -> String {
        if let failure = agent.failureMessage { return failure }
        if let runtimeError = agent.runtimeErrorMessage { return runtimeError }
        if agent.interactionState == .authentication {
            return "Open the terminal and complete \(agent.provider.displayName) sign-in there."
        }
        return "Start this agent when you're ready."
    }

    private func placeholderButtonTitle(for agent: AgentInstance) -> String {
        if agent.canOnlyStartFresh { return "Start Fresh" }
        if agent.interactionState == .authentication { return "Open Terminal to Sign In" }
        if agent.surfaceState == .failed { return "Retry" }
        if agent.runtimeErrorMessage != nil { return "Restart Agent" }
        return "Start Agent"
    }
}

enum AgentCanvasAppearancePolicy {
    static func colorScheme(for backgroundColor: NSColor) -> ColorScheme {
        backgroundColor.isLightColor ? .light : .dark
    }
}
