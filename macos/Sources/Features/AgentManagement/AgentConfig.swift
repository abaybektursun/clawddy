import Foundation

struct AgentProject: Codable, Identifiable {
    var name: String
    var tasks: [AgentTask]
    var workingDirectory: String?
    var id: String { name }
}

struct AgentTask: Codable, Identifiable {
    var name: String
    var agents: [String]
    var id: String { name }
}

struct AgentConfigFile: Codable {
    var projects: [AgentProject]
}

class AgentConfig: ObservableObject {
    @Published var projects: [AgentProject] = []
    private var fileWatcher: DispatchSourceFileSystemObject?

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty-agents/agents.json")
    }

    static var statusDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty-agents/status")
    }

    static func agentKey(project: String, task: String, agent: String) -> String {
        "\(project)/\(task)/\(agent)"
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
    }

    var allAgentNames: [String] {
        projects.flatMap { $0.tasks.flatMap { $0.agents } }
    }

    var allAgentKeys: [String] {
        projects.flatMap { p in
            p.tasks.flatMap { t in
                t.agents.map { Self.agentKey(project: p.name, task: t.name, agent: $0) }
            }
        }
    }

    init() {
        ensureConfigDir()
        ensureHookScripts()
        if !Self.hooksInstalled() { installHooks() }
        load()
        watchFile()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: Self.configURL.path) else { return }
        guard let data = try? Data(contentsOf: Self.configURL) else {
            NSLog("[AgentConfig] Failed to read config file")
            return
        }
        do {
            let config = try JSONDecoder().decode(AgentConfigFile.self, from: data)
            projects = config.projects
            // Debug: write to a log file
            let logLines = projects.map { "\($0.name): cwd=\($0.workingDirectory ?? "nil")" }
            let log = "Loaded \(projects.count) projects:\n" + logLines.joined(separator: "\n") + "\n"
            try? log.write(to: Self.configURL.deletingLastPathComponent().appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        } catch {
            let log = "Decode error: \(error)\n"
            try? log.write(to: Self.configURL.deletingLastPathComponent().appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        }
    }

    func save() {
        let config = AgentConfigFile(projects: projects)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try! encoder.encode(config)
        try! data.write(to: Self.configURL)
    }

    // MARK: - Projects

    func addProject(name: String) {
        guard !name.isEmpty, !projects.contains(where: { $0.name == name }) else { return }
        projects.append(AgentProject(name: name, tasks: []))
        save()
    }

    func removeProject(name: String) {
        projects.removeAll { $0.name == name }
        save()
    }

    func renameProject(old: String, new: String) {
        guard let i = projects.firstIndex(where: { $0.name == old }),
              !projects.contains(where: { $0.name == new })
        else { return }
        projects[i].name = new
        save()
    }

    // MARK: - Tasks

    func addTask(project: String, name: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              !name.isEmpty,
              !projects[pi].tasks.contains(where: { $0.name == name })
        else { return }
        projects[pi].tasks.append(AgentTask(name: name, agents: []))
        save()
    }

    func removeTask(project: String, name: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == name })
        else { return }
        projects[pi].tasks.remove(at: ti)
        save()
    }

    func renameTask(project: String, old: String, new: String) {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == old }),
              !projects[pi].tasks.contains(where: { $0.name == new })
        else { return }
        projects[pi].tasks[ti].name = new
        save()
    }

    // MARK: - Agents

    @discardableResult
    func addAgent(project: String, task: String, name: String) -> Bool {
        guard let pi = projects.firstIndex(where: { $0.name == project }),
              let ti = projects[pi].tasks.firstIndex(where: { $0.name == task }),
              !name.isEmpty,
              !projects[pi].tasks.flatMap(\.agents).contains(name)
        else { return false }
        projects[pi].tasks[ti].agents.append(name)
        save()
        return true
    }

    func removeAgent(name: String) {
        for pi in projects.indices {
            for ti in projects[pi].tasks.indices {
                projects[pi].tasks[ti].agents.removeAll { $0 == name }
            }
        }
        save()
    }

    // MARK: - Hooks

    private static var hooksDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/ghostty-agents/hooks")
    }

    private static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    private static let onSessionStartScript = """
        #!/bin/sh
        # GhosttyAgents — SessionStart hook (captures session ID for resume)
        [ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
        INPUT=$(cat)
        SID=$(echo "$INPUT" | /usr/bin/jq -r '.session_id // empty')
        [ -n "$SID" ] && echo "$SID" > "$HOME/.config/ghostty-agents/status/$GHOSTTY_AGENT_NAME.session"
        """

    private static let onToolScript = """
        #!/bin/sh
        # GhosttyAgents — PostToolUse heartbeat
        [ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
        cat > /dev/null
        DIR="$HOME/.config/ghostty-agents/status"
        date +%s > "$DIR/$GHOSTTY_AGENT_NAME.heartbeat"
        """

    private static let onStopScript = """
        #!/bin/sh
        # GhosttyAgents — Stop hook (Claude finished responding)
        [ -z "$GHOSTTY_AGENT_NAME" ] && cat > /dev/null && exit 0
        cat > /dev/null
        rm -f "$HOME/.config/ghostty-agents/status/$GHOSTTY_AGENT_NAME.heartbeat"
        """

    private func ensureHookScripts() {
        let fm = FileManager.default
        try! fm.createDirectory(at: Self.hooksDir, withIntermediateDirectories: true)

        let scripts: [(String, String)] = [
            ("on-session-start.sh", Self.onSessionStartScript),
            ("on-tool.sh", Self.onToolScript),
            ("on-stop.sh", Self.onStopScript),
        ]

        for (name, content) in scripts {
            let url = Self.hooksDir.appendingPathComponent(name)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if existing == content { continue }
            try! content.write(to: url, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func hooksInstalled() -> Bool {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let str = String(data: data, encoding: .utf8)
        else { return false }
        return str.contains("ghostty-agents/hooks/on-session-start.sh")
            && str.contains("ghostty-agents/hooks/on-tool.sh")
            && str.contains("ghostty-agents/hooks/on-stop.sh")
    }

    private func installHooks() {
        let fm = FileManager.default
        let url = Self.claudeSettingsURL

        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        let backupURL = url.deletingLastPathComponent().appendingPathComponent("settings.json.ghostty-backup")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: url, to: backupURL)
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookEntries: [(String, String)] = [
            ("SessionStart", Self.hooksDir.appendingPathComponent("on-session-start.sh").path),
            ("PostToolUse", Self.hooksDir.appendingPathComponent("on-tool.sh").path),
            ("Stop", Self.hooksDir.appendingPathComponent("on-stop.sh").path),
        ]

        for (event, scriptPath) in hookEntries {
            var eventArray = hooks[event] as? [[String: Any]] ?? []
            let alreadyExists = eventArray.contains { group in
                guard let innerHooks = group["hooks"] as? [[String: Any]] else { return false }
                return innerHooks.contains { ($0["command"] as? String)?.contains("ghostty-agents/hooks/") == true }
            }
            if alreadyExists { continue }
            eventArray.append(["hooks": [["type": "command", "command": scriptPath, "timeout": 5]]])
            hooks[event] = eventArray
        }

        settings["hooks"] = hooks
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private func ensureConfigDir() {
        let dir = Self.configURL.deletingLastPathComponent()
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(at: Self.statusDir, withIntermediateDirectories: true)
    }

    private func watchFile() {
        let path = Self.configURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.load()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileWatcher = source
    }
}
