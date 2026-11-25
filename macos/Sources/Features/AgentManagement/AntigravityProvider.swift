import Foundation

/// agy, the Antigravity CLI (1.5.17; `docs/clawddy-refactor/cli-facts.md`,
/// "agy"). It reports its turns in its terminal (OSC 7501) as Claude does.
/// Its hooks, loaded from a folder of the agent's own that each launch adds
/// with `--add-dir`, bring the conversation's id, the prompt and the full
/// last reply. Nothing of the owner's is written: not their project, not
/// `~/.gemini`.
struct AntigravityProvider: Sendable {
    let id: AgentProviderID = .antigravity
    let root: AgentDataRoot
    /// agy's own data folder (`~/.gemini/antigravity-cli`, or a harness's or
    /// a test's): `conversations/<id>.db` for each conversation and
    /// `presence/<id>.lock`, held while a process has it open. Only read.
    let dataFolder: URL

    static var defaultDataFolder: URL {
        AgentConfig.accountHomeDirectory.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true)
    }

    /// agy's event table. Every record carries the conversation's id, and
    /// each binds it: SessionStart fires only for a conversation made in
    /// this process, never on a resume, and `/clear` or an id agy did not
    /// know changes the id without a word. A turn's prompt is its first
    /// PreInvocation's (`invocationNum` 0); the later ones of the same turn
    /// follow a tool or an answer. Stop brings the full last reply, read
    /// from the transcript. Failures come only from the terminal's `error`:
    /// the one live failure seen ran no hook.
    static let hookEvents: [String: AgentProviderEntry.Meaning] = [
        "SessionStart": { [.sessionBound(sessionID: $0.sessionID)] },
        "PreInvocation": { record in
            var events: [AgentDomainEvent] = [.sessionBound(sessionID: record.sessionID)]
            if record.invocation == "0" { events.append(.promptSubmitted(record.text)) }
            return events
        },
        "Stop": { record in
            [.sessionBound(sessionID: record.sessionID)] + (record.text.map { [.messageReported($0)] } ?? [])
        },
    ]

    /// The payload fields the hook script reads for agy (`cli-facts.md`,
    /// agy, "Hooks"): the event's name, the conversation, the invocation,
    /// and the text each event carries.
    static let eventField = "hookEventName"
    static let sessionField = "conversationId"
    static let invocationField = "invocationNum"
    static let textFields = ["PreInvocation": "lastUserInput"]
    /// The events whose text is the last reply in the transcript the field
    /// names: the last `PLANNER_RESPONSE` with content since the turn's
    /// prompt. The report's message is cut at 200 characters and to the
    /// reply's first line, so the reply comes from here.
    static let transcriptFields = ["Stop": "transcriptPath"]
    /// What each hook prints. agy treats nothing and `{}` alike for these
    /// events (probed); a PreToolUse hook that printed `{}` would deny the
    /// tool, which is why there is none.
    static let hookReply = "{}"

    /// agy's entry in the provider table. Its `working` comes 10 to 20 ms
    /// after Return, and the first prompt's PreInvocation up to 1.24 s after
    /// it in a new conversation (cli-facts.md, agy timelines): a `working`
    /// starts a turn by itself only past that. Every `done` carries the
    /// reply's first line; a sign-in report stood 0.5 s in two of thirteen
    /// signed-in starts, so it counts only once it has stood 2 s; and a
    /// resumed conversation's `working` carries its title, not a step.
    var entry: AgentProviderEntry {
        AgentProviderEntry(
            turnStartDelay: 3,
            reports: AgentReportRules(doneWithMessageCompletes: true, signInStandTime: 2, workingMessageIsActivity: false),
            hookEvents: Self.hookEvents,
            prepareIntegration: { prepareIntegration() },
            prepareLaunch: { prepareLaunch($0) },
            probe: { probe(environmentPath: $0) },
            cleanup: { try cleanup(agentID: $0) })
    }

    /// The only shared file is the hook script in the data root; each
    /// agent's hooks are written at its launch.
    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        do {
            try AgentHookRuntime.install(root: root)
            return .success(.ready)
        } catch {
            return .failure(.integrationFailed(id, error.localizedDescription))
        }
    }

    /// The agent's hook folder, added to each of its launches with
    /// `--add-dir`. Its path never changes: a resumed conversation runs the
    /// hooks of every folder it was made with, so a new path would run
    /// both sets.
    static func hookFolder(root: AgentDataRoot, agentID: UUID) -> URL {
        root.url.appendingPathComponent("agy", isDirectory: true)
            .appendingPathComponent(agentID.uuidString, isDirectory: true)
    }

    /// The hooks file agy loads from a folder given with `--add-dir`: each
    /// event of the table runs the hook script with this launch's identity
    /// as arguments.
    func hooks(agentID: UUID, generation: UUID) -> [String: Any] {
        let command = AgentHookRuntime.command(root: root, provider: id, agentID: agentID, generation: generation)
        let events = Self.hookEvents.mapValues { _ in [["type": "command", "command": command, "timeout": 10]] }
        return ["clawddy": events]
    }

    func prepareLaunch(_ request: AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue> {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: request.environmentPath)
        else { return .failure(.executableMissing(id)) }

        let folder = Self.hookFolder(root: root, agentID: request.agentID)
        let hooksFile = folder.appendingPathComponent(".agents/hooks.json")
        do {
            try FileManager.default.createDirectory(
                at: hooksFile.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(
                withJSONObject: hooks(agentID: request.agentID, generation: request.launchGeneration),
                options: [.prettyPrinted, .sortedKeys])
            try AgentConfig.atomicWrite(data, to: hooksFile)
        } catch {
            // Without its hooks the agent would run with no conversation to
            // resume and no prompts or replies to show.
            return .failure(.launchPreparationFailed(
                id, "Its hook folder \(folder.path) could not be written: \(error.localizedDescription)"))
        }

        var arguments = ["--add-dir", folder.path]
        arguments += id.startModeArguments(request.launchProfile.startMode)
        if let model = request.launchProfile.modelID?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort = request.launchProfile.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines), !effort.isEmpty {
            arguments += ["--effort", effort]
        }
        if let session = request.session, session.provider == id {
            // agy takes an id it does not know as a new conversation without
            // a word, and answers in one already open in another terminal.
            let conversation = session.sessionID
            let stored = dataFolder.appendingPathComponent("conversations/\(conversation).db")
            guard FileManager.default.fileExists(atPath: stored.path) else {
                return .failure(.sessionMissing(id, conversation))
            }
            switch Self.isHeld(dataFolder.appendingPathComponent("presence/\(conversation).lock")) {
            case .success(true): return .failure(.sessionOpenElsewhere(id, conversation))
            case .success(false): break
            case .failure(let issue): return .failure(issue)
            }
            arguments += ["--conversation", conversation]
        }
        // One argument: a prompt that starts with "-" is taken as text
        // (probed, agy 1.5.17).
        if let prompt = request.firstPrompt {
            arguments.append("--prompt-interactive=\(prompt)")
        }
        return .success(AgentPreparedLaunch(
            executableURL: executable,
            arguments: arguments,
            environment: [:],
            metadataAvailability: .waiting))
    }

    /// Whether a process holds the presence lock `file` (an exclusive
    /// `flock`, taken while agy has the conversation open; the file stays
    /// after it exits). No file is no holder.
    static func isHeld(_ file: URL) -> Result<Bool, AgentProviderIssue> {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return .success(false) }
            return .failure(.launchPreparationFailed(
                .antigravity, "\(file.path) could not be opened: \(String(cString: strerror(errno)))"))
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return .success(true) }
            return .failure(.launchPreparationFailed(
                .antigravity, "\(file.path) could not be checked: \(String(cString: strerror(errno)))"))
        }
        flock(descriptor, LOCK_UN)
        return .success(false)
    }

    /// Installed, and its version. agy has no command that reports its
    /// sign-in, so none is asked: its terminal's own sign-in report tells
    /// the person, and one that stands 2 s stops the agent with the login
    /// problem (`AgentReportRules.signInStandTime`).
    func probe(environmentPath: String) -> AgentProviderHealth {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: environmentPath)
        else {
            return AgentProviderHealth(
                installation: .missing,
                authentication: .unavailable("Antigravity is not installed."))
        }
        let version = AgentProcessProbe.run(
            executable: executable,
            arguments: ["--version"],
            environmentPath: environmentPath).successfulOutput
        return AgentProviderHealth(
            installation: .ready(executable: executable.path, version: version),
            authentication: .unavailable("Antigravity reports its sign-in only in its terminal."))
    }

    func cleanup(agentID: UUID) throws {
        try FileManager.default.removeItemIfPresent(at: Self.hookFolder(root: root, agentID: agentID))
    }
}
