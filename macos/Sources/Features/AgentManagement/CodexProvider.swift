import Foundation

struct CodexProvider: Sendable {
    let id: AgentProviderID = .codex
    let root: AgentDataRoot
    /// The Codex configuration whose own `notify` program each launch's
    /// notify program runs first (`~/.codex/config.toml`, or a harness's
    /// file of its own).
    let configFile: URL

    /// Codex's event table. Codex reports its turns in its terminal (OSC
    /// 7501): `working` at a turn's start, `error` on a failure, `idle` on an
    /// interrupt. Its per-launch notify program adds what the terminal
    /// lacks: at each completed turn its session, its prompts and its last
    /// message. Codex also notifies for the turn in which it titles a new
    /// conversation, on a thread of its own; that notify is no turn of the
    /// agent's and changes nothing.
    static let hookEvents: [String: AgentProviderEntry.Meaning] = [
        "agent-turn-complete": { record in
            let prompts = record.prompts ?? []
            if prompts.first?.hasPrefix(titleInstruction) == true { return [] }
            var events: [AgentDomainEvent] = [.sessionBound(sessionID: record.sessionID)]
            events += prompts.map { .promptSubmitted($0) }
            events.append(.turnCompleted(turnID: record.turnID))
            if let text = record.text { events.append(.messageReported(text)) }
            return events
        },
    ]

    /// How the prompt of Codex's own title turn begins (Codex 0.169.0).
    static let titleInstruction = "Generate a concise, single-line task title"

    /// The notify payload field that names Codex's turn.
    static let turnIDField = "turn-id"
    /// The payload field whose text each event carries.
    static let textFields = ["agent-turn-complete": "last-assistant-message"]
    /// The payload field that lists the completed turn's prompts.
    static let promptsField = "input-messages"

    /// Codex's entry in the provider table. Its start-up `working`, before
    /// any prompt, lasts 0.7 to 2.4 s (probes, 2026-11-23); a `working` that
    /// stands longer than that starts a turn.
    var entry: AgentProviderEntry {
        AgentProviderEntry(
            turnStartDelay: 3,
            reports: .standard,
            hookEvents: Self.hookEvents,
            prepareIntegration: { prepareIntegration() },
            prepareLaunch: { prepareLaunch($0) },
            probe: { probe(environmentPath: $0) },
            cleanup: { _ in })
    }

    /// The only file this writes is the hook script in the data root, which
    /// each launch names as its notify program.
    func prepareIntegration() -> Result<AgentIntegrationPreparation, AgentProviderIssue> {
        do {
            try AgentHookRuntime.install(root: root)
            return .success(.ready)
        } catch {
            return .failure(.integrationFailed(id, error.localizedDescription))
        }
    }

    func prepareLaunch(_ request: AgentLaunchRequest) -> Result<AgentPreparedLaunch, AgentProviderIssue> {
        guard let executable = AgentExecutableLocator.locate(
            id.executableName,
            path: request.environmentPath)
        else { return .failure(.executableMissing(id)) }

        let ownerNotify: [String]
        do {
            ownerNotify = try Self.notifyCommand(inConfig: configFile)
        } catch {
            return .failure(.launchPreparationFailed(
                id,
                "\(configFile.path) could not be read: \(error.localizedDescription)"))
        }
        let notify = AgentHookRuntime.arguments(
            root: root,
            provider: id,
            agentID: request.agentID,
            generation: request.launchGeneration) + [AgentHookRuntime.notifyMode] + ownerNotify

        var globalArguments: [String] = ["-c", "notify=\(Self.tomlArray(notify))"]
        globalArguments += id.startModeArguments(request.launchProfile.startMode)
        if let model = normalized(request.launchProfile.modelID) {
            globalArguments += ["--model", model]
        }
        if let effort = normalizedEffort(request.launchProfile.reasoningEffort) {
            globalArguments += ["--config", "model_reasoning_effort=\"\(effort)\""]
        }

        var arguments: [String]
        if let session = request.session, session.provider == id {
            // The same conversation must never run twice (flows.md 4.5).
            let processes = request.liveSessions.listing(id) {
                Self.processes(environmentPath: request.environmentPath)
            }
            switch processes.map({ Self.holdsSession(session.sessionID, processes: $0, except: getpid()) }) {
            case .success(true): return .failure(.sessionOpenElsewhere(id, session.sessionID))
            case .success(false): break
            case .failure(let issue): return .failure(issue)
            }
            arguments = globalArguments + ["resume", session.sessionID]
        } else {
            arguments = globalArguments
        }
        // After `--`, a task that starts with "-" is never read as an option
        // (Codex 0.169.0 takes it so, probed 2026-11-24).
        if let prompt = request.firstPrompt {
            arguments += ["--", prompt]
        }

        var environment: [String: String] = [:]
        if let configURL = AgentConfig.codexConfigEnvironmentOverride {
            environment["CODEX_HOME"] = configURL.path
        }
        return .success(AgentPreparedLaunch(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            metadataAvailability: .waiting))
    }

    /// The owner's own `notify` command: the top-level `notify` array of
    /// strings in Codex's `config.toml`, empty when the file or the key is
    /// absent. A `-c notify=` on the command line replaces it, so the
    /// launch's notify program runs it.
    static func notifyCommand(inConfig file: URL) throws -> [String] {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        // Keys before the first table header are top-level.
        var topLevel = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("[") { break }
            topLevel += line + "\n"
        }
        guard let key = topLevel.range(of: #"(?m)^[ \t]*notify[ \t]*=[ \t]*\["#, options: .regularExpression)
        else { return [] }
        return try tomlStrings(topLevel[key.upperBound...])
    }

    /// The strings of a TOML array, from just after its `[` to its `]`:
    /// basic strings with their escapes, and literal strings.
    private static func tomlStrings(_ text: Substring) throws -> [String] {
        var strings: [String] = []
        var index = text.startIndex
        func fail() -> Error {
            CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "its notify value is not an array of strings",
            ])
        }
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            switch character {
            case "]": return strings
            case " ", "\t", "\n", "\r", ",": continue
            case "#":
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
            case "'":
                guard let close = text[index...].firstIndex(of: "'") else { throw fail() }
                strings.append(String(text[index..<close]))
                index = text.index(after: close)
            case "\"":
                var value = ""
                while true {
                    guard index < text.endIndex else { throw fail() }
                    let next = text[index]
                    index = text.index(after: index)
                    if next == "\"" { break }
                    guard next == "\\" else { value.append(next); continue }
                    guard index < text.endIndex else { throw fail() }
                    let escape = text[index]
                    index = text.index(after: index)
                    switch escape {
                    case "n": value.append("\n")
                    case "t": value.append("\t")
                    case "r": value.append("\r")
                    case "\"", "\\": value.append(escape)
                    case "u", "U":
                        let length = escape == "u" ? 4 : 8
                        guard let end = text.index(index, offsetBy: length, limitedBy: text.endIndex),
                              let code = UInt32(text[index..<end], radix: 16),
                              let scalar = Unicode.Scalar(code)
                        else { throw fail() }
                        value.unicodeScalars.append(scalar)
                        index = end
                    default: throw fail()
                    }
                }
                strings.append(value)
            default: throw fail()
            }
        }
        throw fail()
    }

    /// `strings` as a TOML array of basic strings, as `-c` takes it.
    static func tomlArray(_ strings: [String]) -> String {
        let items = strings.map { string -> String in
            var escaped = ""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": escaped += "\\\""
                case "\\": escaped += "\\\\"
                case "\n": escaped += "\\n"
                case "\t": escaped += "\\t"
                case "\r": escaped += "\\r"
                default:
                    if scalar.value < 0x20 || scalar.value == 0x7F {
                        escaped += String(format: "\\u%04X", scalar.value)
                    } else {
                        escaped.unicodeScalars.append(scalar)
                    }
                }
            }
            return "\"\(escaped)\""
        }
        return "[" + items.joined(separator: ",") + "]"
    }

    /// The running processes with their command lines (`ps -axo
    /// pid=,args=`). Codex lists no running sessions, and its session file
    /// stays open in its app-server daemon after the terminal that used it
    /// has gone (probed 2026-11-24, Codex 0.169.0), so the one observable
    /// sign of a live session is a process given its id on its command line
    /// (`codex resume <id>`, `holdsSession`). A session started fresh in
    /// another terminal names no id and is not seen.
    static func processes(environmentPath: String) -> Result<String, AgentProviderIssue> {
        let outcome = AgentProcessProbe.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,args="],
            environmentPath: environmentPath)
        guard let output = outcome.successfulOutput else {
            return .failure(.launchPreparationFailed(.codex, "The list of running processes could not be read (\(outcome))."))
        }
        return .success(output)
    }

    /// Whether one of `processes` (`ps -o pid=,args=` lines) is a Codex
    /// terminal given `sessionID`, other than `except`.
    static func holdsSession(_ sessionID: String, processes: String, except: pid_t) -> Bool {
        processes.split(separator: "\n").contains { line in
            let words = line.split(separator: " ")
            guard let pid = words.first.flatMap({ pid_t($0) }), pid != except,
                  let codex = words.dropFirst().firstIndex(where: { $0.hasSuffix("/codex") || $0 == "codex" })
            else { return false }
            let rest = words[(codex + 1)...]
            return !rest.contains("app-server") && rest.contains(Substring(sessionID))
        }
    }

    func probe(environmentPath: String) -> AgentProviderHealth {
        guard let executable = AgentExecutableLocator.locate(id.executableName, path: environmentPath)
        else {
            return AgentProviderHealth(
                installation: .missing,
                authentication: .unavailable("Codex is not installed."))
        }
        let version = AgentProcessProbe.run(
            executable: executable,
            arguments: ["--version"],
            environmentPath: environmentPath).successfulOutput
        let auth = AgentProcessProbe.run(
            executable: executable,
            arguments: ["login", "status"],
            environmentPath: environmentPath,
            additionalEnvironment: AgentConfig.codexConfigEnvironmentOverride.map {
                ["CODEX_HOME": $0.path]
            } ?? [:])
        return AgentProviderHealth(
            installation: .ready(executable: executable.path, version: version),
            authentication: Self.authenticationState(from: auth))
    }

    static func authenticationState(
        from outcome: AgentProcessProbe.Outcome
    ) -> AgentProviderAuthState {
        let result: AgentProcessProbe.Result
        switch outcome {
        case .completed(let completed): result = completed
        case .launchFailed:
            return .unavailable("Codex sign-in status could not be started.")
        case .timedOut:
            return .unavailable("Codex sign-in status timed out.")
        }
        if result.status == 0 { return .signedIn }
        let output = (result.output + "\n" + result.errors).lowercased()
        if output.contains("not logged in") || output.contains("not signed in") {
            return .signedOut
        }
        return .unavailable("Codex returned an unreadable sign-in status.")
    }

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func normalizedEffort(_ value: String?) -> String? {
        guard let value = normalized(value)?.lowercased(),
              value.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(
                      CharacterSet(charactersIn: "_-")).contains($0)
              })
        else { return nil }
        return value
    }

    /// Older Clawddy builds registered the hook script in Codex's global
    /// `hooks.json`. Removes the entries that run `root`'s script and nothing
    /// else, writing only when one was found. Only the production identity,
    /// which owns that script path, ever writes the file. Returns whether it
    /// was written.
    static func removeGlobalHooks(
        hooksFile: URL,
        root: AgentDataRoot,
        isProduction: Bool
    ) throws -> Bool {
        guard isProduction else { return false }
        return try AgentHookRuntime.updateJSONFile(
            at: hooksFile,
            backupURL: hooksFile.appendingPathExtension("clawddy-backup")
        ) { file in
            guard let hooks = file["hooks"] as? [String: Any] else { return }
            file["hooks"] = AgentHookRuntime.removingHandlers(runningScriptOf: root, from: hooks)
        }
    }
}
