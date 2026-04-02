import AppKit
import SwiftUI
import GhosttyKit

/// Hosts the active agent's terminal surface in the detail pane.
/// Surfaces are created on first activation and hidden (not destroyed) when switching.
final class AgentDetailViewController: NSViewController {

    private var surfaces: [String: Ghostty.SurfaceView] = [:]
    private var activeKey: String?
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

    /// Show an existing surface or create a new one.
    /// The `createConfig` closure is only called if the surface doesn't exist yet.
    /// Returns true if a new surface was created.
    @discardableResult
    func showOrSwitch(
        key: String,
        displayName: String,
        projectName: String,
        createConfig: () -> (ghostty_app_t, Ghostty.SurfaceConfiguration)
    ) -> Bool {
        // Update header
        headerModel.agentName = displayName
        headerModel.projectName = projectName
        headerModel.isActive = true
        placeholderView?.isHidden = true

        // Hide current surface
        if let currentKey = activeKey, let current = surfaces[currentKey] {
            current.isHidden = true
        }

        var isNew = false

        // Create surface only if it doesn't exist
        if surfaces[key] == nil {
            let (app, config) = createConfig()
            let surface = Ghostty.SurfaceView(app, baseConfig: config)
            surface.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.topAnchor.constraint(equalTo: terminalTopAnchor),
                surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            surfaces[key] = surface
            isNew = true
        }

        // Show target surface
        surfaces[key]!.isHidden = false
        activeKey = key

        DispatchQueue.main.async {
            self.view.window?.makeFirstResponder(self.surfaces[key])
        }

        return isNew
    }

    /// Destroy a specific agent's surface.
    func removeSurface(key: String) {
        if let surface = surfaces.removeValue(forKey: key) {
            surface.removeFromSuperview()
        }
        if activeKey == key {
            activeKey = nil
            headerModel.isActive = false
            placeholderView?.isHidden = false
        }
    }

    /// Whether a surface exists for this key.
    func hasSurface(key: String) -> Bool {
        surfaces[key] != nil
    }
}

// MARK: - Header

class AgentDetailHeaderModel: ObservableObject {
    @Published var agentName: String = ""
    @Published var projectName: String = ""
    @Published var isActive: Bool = false
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
        .background(.bar)
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
        }
    }
}
