import AppKit
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
final class AgentDetailViewController: NSViewController {

    private weak var ghostty: Ghostty.App?

    private var hostsByID: [UUID: AgentTerminalHost] = [:]
    private var hostingViewsByID: [UUID: TerminalViewContainer] = [:]
    private var surfacesByID: [UUID: Ghostty.SurfaceView] = [:]
    private(set) var activeID: UUID?

    private var placeholderView: NSView?
    private var headerHosting: NSHostingView<AgentDetailHeaderView>?
    private var headerModel = AgentDetailHeaderModel()

    private var keyObservers: [NSObjectProtocol] = []

    init(ghostty: Ghostty.App) {
        self.ghostty = ghostty
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

        let headerView = NSHostingView(rootView: AgentDetailHeaderView(model: headerModel))
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

        let placeholder = NSHostingView(rootView: AgentPlaceholderView(model: headerModel))
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        placeholderView = placeholder
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
            self?.activeHost?.syncFocus()
        }
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: onKey))
        keyObservers.append(nc.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: onKey))
    }

    private var activeHost: AgentTerminalHost? {
        guard let id = activeID else { return nil }
        return hostsByID[id]
    }

    /// Reconcile Ghostty's logical focus after AppKit accepts any responder
    /// transition in the workspace window. This is required for field editors:
    /// the real first responder is an NSTextView owned by NSWindow, not the
    /// SwiftUI TextField that initiated editing.
    func workspaceFirstResponderDidChange() {
        activeHost?.syncFocus()
    }

    /// Update the detail selection without launching work or stealing focus.
    func selectAgent(
        _ agent: AgentInstance,
        projectName: String,
        onStart: (() -> Void)? = nil
    ) {
        if headerModel.agent?.id != agent.id {
            headerModel.showsAgentDetails = false
        }
        headerModel.agent = agent
        headerModel.projectName = projectName
        headerModel.isActive = true
        if let onStart {
            headerModel.onStart = onStart
        }
        headerModel.onFocusTerminal = { [weak self] in self?.focusTerminal() }

        if let previousID = activeID, previousID != agent.id {
            hostsByID[previousID]?.focusedSurface = nil
            detachContainer(id: previousID)
        }

        activeID = agent.id
        let hasSurface = hostsByID[agent.id] != nil
        headerModel.hasSurface = hasSurface
        if hasSurface {
            attachContainer(id: agent.id)
        }
        placeholderView?.isHidden = hasSurface
        installWindowKeyObserversIfNeeded()
    }

    /// Show an existing agent's terminal or create a new one after an explicit action.
    @discardableResult
    func showOrSwitch(
        id: UUID,
        displayName: String,
        projectName: String,
        agent: AgentInstance,
        focusTerminal: Bool = true,
        createConfig: () -> (ghostty_app_t, Ghostty.SurfaceConfiguration)?
    ) -> Bool {
        selectAgent(agent, projectName: projectName)

        var isNew = false

        if hostsByID[id] == nil {
            guard let ghostty else { fatalError("AgentDetailViewController used without ghostty") }
            guard let (app, config) = createConfig() else {
                headerModel.hasSurface = false
                placeholderView?.isHidden = false
                return false
            }
            let surface = Ghostty.SurfaceView(app, baseConfig: config)
            let host = AgentTerminalHost()
            host.surfaceTree = SplitTree(view: surface)

            let container = TerminalViewContainer {
                TerminalView(ghostty: ghostty, viewModel: host, delegate: host)
            }
            container.translatesAutoresizingMaskIntoConstraints = false

            host.hostingWindow = view.window
            hostsByID[id] = host
            hostingViewsByID[id] = container
            surfacesByID[id] = surface
            attachContainer(id: id)
            isNew = true
            headerModel.hasSurface = true
            logger.info("created host for agent \(id)")
        }

        attachContainer(id: id)
        placeholderView?.isHidden = true
        if let host = hostsByID[id], let surface = surfacesByID[id] {
            // The window can change between creation and show (rare); re-anchor.
            host.hostingWindow = view.window
            host.focusedSurface = surface
            // Canonical focus move. Handles "view not yet in a window" via backoff,
            // and pairs resignFirstResponder on the previous focused surface.
            if focusTerminal {
                Ghostty.moveFocus(to: surface)
            }
        }
        activeID = id

        installWindowKeyObserversIfNeeded()

        return isNew
    }

    func focusTerminal() {
        guard let activeID, let surface = surfacesByID[activeID] else { return }
        Ghostty.moveFocus(to: surface)
    }

    func showAgentDetails() {
        guard headerModel.agent != nil else { return }
        headerModel.showsAgentDetails = true
    }

    func removeSurface(id: UUID) {
        logger.info("removeSurface \(id)")
        hostingViewsByID.removeValue(forKey: id)?.removeFromSuperview()
        hostsByID[id]?.focusedSurface = nil
        hostsByID.removeValue(forKey: id)
        surfacesByID.removeValue(forKey: id)
        if activeID == id {
            headerModel.hasSurface = false
            placeholderView?.isHidden = false
        }
    }

    func showPlaceholder() {
        if let activeID {
            hostsByID[activeID]?.focusedSurface = nil
            detachContainer(id: activeID)
        }
        activeID = nil
        headerModel.isActive = false
        headerModel.agent = nil
        headerModel.hasSurface = false
        headerModel.showsAgentDetails = false
        placeholderView?.isHidden = false
    }

    func hasSurface(id: UUID) -> Bool { hostsByID[id] != nil }

    var hasActiveSurface: Bool {
        guard let activeID else { return false }
        return hostsByID[activeID] != nil
    }

    func surfaceView(for id: UUID) -> Ghostty.SurfaceView? { surfacesByID[id] }

    private func attachContainer(id: UUID) {
        guard let container = hostingViewsByID[id], container.superview == nil else { return }
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: terminalTopAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func detachContainer(id: UUID) {
        hostingViewsByID[id]?.removeFromSuperview()
    }

    /// Send text to a specific agent's terminal pty.
    func sendText(_ text: String, toAgent id: UUID) {
        guard let surface = surfacesByID[id]?.surfaceModel else { return }
        surface.sendText(text)
    }

    /// Set background color to match Ghostty's terminal theme.
    func setBackgroundColor(_ color: NSColor) {
        headerModel.backgroundColor = Color(nsColor: .windowBackgroundColor)
        view.layer?.backgroundColor = color.cgColor
    }
}

// MARK: - Header

@Observable
class AgentDetailHeaderModel {
    var agent: AgentInstance?
    var projectName: String = ""
    var isActive: Bool = false
    var hasSurface: Bool = false
    var showsAgentDetails: Bool = false
    var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
    @ObservationIgnored var onStart: (() -> Void)?
    @ObservationIgnored var onFocusTerminal: (() -> Void)?
}

private struct AgentDetailHeaderView: View {
    var model: AgentDetailHeaderModel

    var body: some View {
        @Bindable var bindableModel = model
        VStack(spacing: 0) {
            if model.isActive, let agent = model.agent {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.name)
                            .font(.headline)
                            .lineLimit(1)
                        Text(model.projectName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 16)

                    Label(agent.displayState.label, systemImage: agent.displayState.iconName ?? "circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(agent.displayState.color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(agent.displayState.color.opacity(0.1), in: Capsule())

                    if model.hasSurface {
                        Button("Focus Terminal", systemImage: "terminal") {
                            model.onFocusTerminal?()
                        }
                        .buttonStyle(.bordered)
                        .accessibilitySortPriority(1)
                    } else {
                        Button(primaryActionTitle(for: agent), systemImage: "play.fill") {
                            model.onStart?()
                        }
                        .buttonStyle(.borderedProminent)
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
        switch agent.processState {
        case .failed: return "Retry"
        case .dead: return "Restart"
        default: return "Start"
        }
    }
}

// MARK: - Placeholder

private struct AgentPlaceholderView: View {
    var model: AgentDetailHeaderModel

    var body: some View {
        VStack(spacing: 12) {
            if let agent = model.agent {
                Image(systemName: agent.processState == .failed
                    ? "exclamationmark.triangle" : "terminal")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(agent.processState == .failed ? .red : .secondary)

                Text(agent.processState == .failed ? "Couldn't Start Agent" : "Ready to Start")
                    .font(.title3.weight(.semibold))

                Text(agent.failureMessage ?? "Start this agent when you're ready.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button(agent.processState == .failed ? "Retry" : "Start Agent") {
                    model.onStart?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Select an Agent")
                    .font(.title3.weight(.semibold))

                Text("Choose an agent in the sidebar to view its status and terminal.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .accessibilityElement(children: .contain)
    }
}
