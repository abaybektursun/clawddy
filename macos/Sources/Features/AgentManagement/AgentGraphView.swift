import SwiftUI
import GhosttyKit

private enum EditTarget: Equatable {
    case project(String)
    case task(project: String, task: String)
    case newAgent(project: String, task: String)
}

struct AgentGraphView: View {
    @ObservedObject var config: AgentConfig
    @ObservedObject var bridge: AgentTerminalBridge
    let ghostty: Ghostty.App

    @State private var editing: EditTarget?
    @State private var editText = ""
    @State private var deleteTarget: String?
    @State private var shakeEditor = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(config.projects) { project in
                        projectSection(project)
                    }

                    if config.projects.isEmpty {
                        Text("Create your first project")
                            .font(.system(.callout, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(20)
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 460, minHeight: 360)
    }

    // MARK: - Project

    private func projectSection(_ project: AgentProject) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if editing == .project(project.name) {
                    TextField("Project name", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(.footnote, design: .monospaced, weight: .semibold))
                        .onSubmit { confirmRenameProject(old: project.name) }
                        .onExitCommand { editing = nil }
                } else {
                    HStack(spacing: 8) {
                        Text(project.name.uppercased())
                            .font(.system(.footnote, design: .monospaced, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(.secondary)
                            .onTapGesture(count: 2) {
                                editText = project.name
                                editing = .project(project.name)
                            }

                        if let dir = project.workingDirectory {
                            Text(compactPath(dir))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.quaternary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                if deleteTarget == project.name {
                    Button {
                        for task in project.tasks {
                            for agent in task.agents {
                                bridge.stopTracking(agent: AgentConfig.agentKey(project: project.name, task: task.name, agent: agent))
                            }
                        }
                        withAnimation(.snappy) { config.removeProject(name: project.name) }
                        deleteTarget = nil
                    } label: {
                        Text("Delete")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.red.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.smooth) { deleteTarget = nil }
                    } label: {
                        Text("Cancel")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { pickWorkingDirectory(project: project.name) } label: {
                        Image(systemName: "folder")
                            .font(.system(.caption2, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(project.workingDirectory != nil ? Color.accentColor : Color.secondary.opacity(0.4))
                    .help("Working directory")

                    Button {
                        let name = "Task \(project.tasks.count + 1)"
                        config.addTask(project: project.name, name: name)
                        editText = name
                        editing = .task(project: project.name, task: name)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(.caption2, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Add task")

                    Button {
                        withAnimation(.snappy) { deleteTarget = project.name }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(.caption2, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Delete project")
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(project.tasks) { task in
                    taskSection(project: project, task: task)
                }
            }
        }
        .padding(16)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func confirmRenameProject(old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != old { config.renameProject(old: old, new: new) }
        editing = nil
    }

    private func pickWorkingDirectory(project name: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        panel.message = "Working directory for all agents in this project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let i = config.projects.firstIndex(where: { $0.name == name }) else { return }
        config.projects[i].workingDirectory = url.path
        config.save()
    }

    private func compactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) { return "~" + path.dropFirst(home.count) }
        return path
    }

    // MARK: - Task

    private func taskSection(project: AgentProject, task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if editing == .task(project: project.name, task: task.name) {
                    TextField("Task name", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .onSubmit { confirmRenameTask(project: project.name, old: task.name) }
                        .onExitCommand { editing = nil }
                } else {
                    Text(task.name)
                        .font(.system(.caption2, design: .monospaced, weight: .medium))
                        .tracking(0.5)
                        .foregroundStyle(.tertiary)
                        .onTapGesture(count: 2) {
                            editText = task.name
                            editing = .task(project: project.name, task: task.name)
                        }
                }

                Spacer()

                Button {
                    withAnimation(.snappy) { config.removeTask(project: project.name, name: task.name) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(.caption2, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.quaternary)
            }

            FlowLayout(spacing: 10) {
                ForEach(task.agents, id: \.self) { agent in
                    let key = AgentConfig.agentKey(project: project.name, task: task.name, agent: agent)
                    AgentNodeView(
                        name: agent,
                        state: bridge.state(for: key),
                        onTap: {
                            bridge.openOrActivate(
                                key: key,
                                displayName: agent,
                                workingDirectory: project.workingDirectory ?? NSHomeDirectory(),
                                ghostty: ghostty
                            )
                        },
                        onDelete: {
                            bridge.stopTracking(agent: key)
                            withAnimation(.snappy) { config.removeAgent(name: agent) }
                        }
                    )
                }

                if editing == .newAgent(project: project.name, task: task.name) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: 8, height: 8)
                        TextField("name", text: $editText)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced, weight: .medium))
                            .frame(width: 80)
                            .onSubmit {
                                let name = editText.trimmingCharacters(in: .whitespaces)
                                if config.addAgent(project: project.name, task: task.name, name: name) {
                                    editText = ""
                                    editing = nil
                                } else {
                                    withAnimation(.spring(duration: 0.3, bounce: 0.6)) { shakeEditor = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { shakeEditor = false }
                                }
                            }
                            .onExitCommand { editing = nil }
                    }
                    .offset(x: shakeEditor ? -6 : 0)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                            .foregroundStyle(shakeEditor ? Color.red.opacity(0.4) : Color.primary.opacity(0.15))
                    )
                } else {
                    Button {
                        editText = ""
                        editing = .newAgent(project: project.name, task: task.name)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(.body, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .help("Add agent")
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func confirmRenameTask(project: String, old: String) {
        let new = editText.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty && new != old { config.renameTask(project: project, old: old, new: new) }
        editing = nil
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack {
            Button {
                let name = "Project \(config.projects.count + 1)"
                config.addProject(name: name)
                editText = name
                editing = .project(name)
            } label: {
                Label("New Project", systemImage: "plus.circle.fill")
                    .font(.system(.caption, weight: .medium))
            }
            .buttonStyle(.plain)

            Spacer()

            let count = config.allAgentNames.count
            Text("\(count) agent\(count == 1 ? "" : "s")")
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        for row in rows {
            let rowH = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            height += rowH + (height > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            let rowH = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            var x = bounds.minX
            for sub in row {
                let size = sub.sizeThatFits(.unspecified)
                sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowH + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxW = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var w: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if w + size.width > maxW && !rows[rows.count - 1].isEmpty {
                rows.append([])
                w = 0
            }
            rows[rows.count - 1].append(sub)
            w += size.width + spacing
        }
        return rows
    }
}
