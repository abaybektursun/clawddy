import AppKit
import SwiftUI
import GhosttyKit
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentDetail")

/// Hosts the active agent's terminal surface in the detail pane.
/// All keys are UUID-based. Zero rekey on rename.
final class AgentDetailViewController: NSViewController {

    private var surfaceWrappersByID: [UUID: SurfaceScrollView] = [:]
    private var surfaceViewsByID: [UUID: Ghostty.SurfaceView] = [:]
    private(set) var activeID: UUID?
    private var placeholderView: NSView?
    private var headerHosting: NSHostingView<AgentDetailHeaderView>?
    private var headerModel = AgentDetailHeaderModel()

    private let headerHeight: CGFloat = 36

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        let headerView = NSHostingView(rootView: AgentDetailHeaderView(model: headerModel))
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: headerHeight),
        ])
        headerHosting = headerView

        let placeholder = NSHostingView(rootView: AgentPlaceholderView())
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: headerHeight / 2),
        ])
        placeholderView = placeholder
    }

    private var terminalTopAnchor: NSLayoutYAxisAnchor {
        headerHosting!.bottomAnchor
    }

    /// Show existing surface or create new. Returns true if new surface created.
    @discardableResult
    func showOrSwitch(
        id: UUID,
        displayName: String,
        projectName: String,
        createConfig: () -> (ghostty_app_t, Ghostty.SurfaceConfiguration)
    ) -> Bool {
        headerModel.agentName = displayName
        headerModel.projectName = projectName
        headerModel.isActive = true
        placeholderView?.isHidden = true

        // Hide current
        if let currentID = activeID, let current = surfaceWrappersByID[currentID] {
            current.isHidden = true
        }

        var isNew = false

        if surfaceWrappersByID[id] == nil {
            logger.info("creating surface for \(id)")
            let (app, config) = createConfig()
            let surfaceView = Ghostty.SurfaceView(app, baseConfig: config)
            let scrollWrapper = SurfaceScrollView(
                contentSize: view.bounds.size,
                surfaceView: surfaceView
            )
            scrollWrapper.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scrollWrapper)
            NSLayoutConstraint.activate([
                scrollWrapper.topAnchor.constraint(equalTo: terminalTopAnchor),
                scrollWrapper.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollWrapper.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollWrapper.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            surfaceWrappersByID[id] = scrollWrapper
            surfaceViewsByID[id] = surfaceView
            isNew = true
        }

        surfaceWrappersByID[id]!.isHidden = false
        activeID = id

        DispatchQueue.main.async {
            if let surface = self.surfaceViewsByID[id] {
                self.view.window?.makeFirstResponder(surface)
            }
        }

        return isNew
    }

    func removeSurface(id: UUID) {
        logger.info("removeSurface \(id)")
        if let wrapper = surfaceWrappersByID.removeValue(forKey: id) {
            wrapper.removeFromSuperview()
        }
        surfaceViewsByID.removeValue(forKey: id)
        if activeID == id {
            showPlaceholder()
        }
    }

    func showPlaceholder() {
        activeID = nil
        headerModel.isActive = false
        placeholderView?.isHidden = false
    }

    func hasSurface(id: UUID) -> Bool {
        surfaceWrappersByID[id] != nil
    }

    func surfaceView(for id: UUID) -> Ghostty.SurfaceView? {
        surfaceViewsByID[id]
    }

    func surfaceWrapper(for id: UUID) -> SurfaceScrollView? {
        surfaceWrappersByID[id]
    }

    /// Send text to a specific agent's terminal pty.
    func sendText(_ text: String, toAgent id: UUID) {
        guard let surface = surfaceViewsByID[id]?.surfaceModel else { return }
        surface.sendText(text)
    }

    /// Set background color to match Ghostty's terminal theme.
    func setBackgroundColor(_ color: NSColor) {
        headerModel.backgroundColor = Color(nsColor: color)
        view.layer?.backgroundColor = color.cgColor
    }
}

// MARK: - Header

class AgentDetailHeaderModel: ObservableObject {
    @Published var agentName: String = ""
    @Published var projectName: String = ""
    @Published var isActive: Bool = false
    @Published var backgroundColor: Color = Color(nsColor: .windowBackgroundColor)
}

private struct AgentDetailHeaderView: View {
    @ObservedObject var model: AgentDetailHeaderModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isActive {
                Text(model.projectName)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text("/")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.quaternary)

                Text(model.agentName)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(model.backgroundColor.opacity(0.9))
    }
}

// MARK: - Placeholder

private struct AgentPlaceholderView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.quaternary)

            Text("Select an agent")
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(.tertiary)

            Text("Click an agent in the sidebar to open its terminal")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.quaternary)

            Text("Clawddy")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.quaternary.opacity(0.5))
                .padding(.top, 8)
        }
    }
}
