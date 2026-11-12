import Foundation

enum AgentHookRuntime {
    static func scriptURL(root: AgentDataRoot) -> URL {
        root.hooksDir.appendingPathComponent("clawddy-provider-hook.sh")
    }

    /// Codex's global hook command: the status folder only. The agent's
    /// identity comes from the `CLAWDDY_*` variables of its terminal.
    static func command(root: AgentDataRoot) -> String {
        "\(shellQuote(scriptURL(root: root).path)) \(shellQuote(root.statusDir.path))"
    }

    /// A Claude agent's hook command, written into its own settings overlay:
    /// the status folder followed by the agent's identity as arguments.
    static func command(
        root: AgentDataRoot,
        provider: AgentProviderID,
        agentID: UUID,
        generation: UUID
    ) -> String {
        [command(root: root), provider.rawValue, agentID.uuidString, generation.uuidString]
            .joined(separator: " ")
    }

    /// Arguments: STATUS_DIR PROVIDER AGENT_ID GENERATION. A Claude agent's
    /// settings overlay passes all four. Codex's global entry passes only
    /// STATUS_DIR, and the other three then come from CLAWDDY_AGENT_PROVIDER,
    /// CLAWDDY_AGENT_ID and CLAWDDY_AGENT_GENERATION, but only when
    /// CLAWDDY_STATUS_DIR names that same folder, so an agent started by
    /// another Clawddy instance is never recorded here. Without a complete
    /// identity the script drains its input and records nothing; it exits 0,
    /// because an argument-less global entry left by an older Clawddy must not
    /// report a hook error in every Claude session on the machine. The script
    /// only appends records; the bridge writes the session binding from them.
    static let script = """
        #!/bin/sh
        umask 077
        DIR="$1"
        PROVIDER="$2"
        ID="$3"
        GENERATION="$4"
        if [ "$#" -eq 1 ] && [ "${CLAWDDY_STATUS_DIR:-}" = "$DIR" ]; then
          PROVIDER="${CLAWDDY_AGENT_PROVIDER:-}"
          ID="${CLAWDDY_AGENT_ID:-}"
          GENERATION="${CLAWDDY_AGENT_GENERATION:-}"
        fi
        if [ -z "$DIR" ] || [ -z "$PROVIDER" ] || [ -z "$ID" ] || [ -z "$GENERATION" ]; then
          cat >/dev/null
          exit 0
        fi

        mkdir -p "$DIR" 2>/dev/null || exit 0

        INPUT="${TMPDIR:-/tmp}/clawddy-hook-$ID-$$.json"
        trap 'rm -f "$INPUT"' EXIT HUP INT TERM
        cat > "$INPUT" || exit 0
        chmod 600 "$INPUT" 2>/dev/null

        extract() {
          /usr/bin/plutil -extract "$1" raw -o - "$INPUT" 2>/dev/null || true
        }
        sanitize() {
          printf '%s' "$1" | /usr/bin/tr -cd '[:alnum:]_.:/-'
        }

        SID=$(sanitize "$(extract session_id)")
        EVENT=$(sanitize "$(extract hook_event_name)")
        TURN=$(sanitize "$(extract turn_id)")
        MODEL=$(sanitize "$(extract model)")
        PERMISSION=$(sanitize "$(extract permission_mode)")
        EVENT_ID=$(sanitize "$(/usr/bin/uuidgen 2>/dev/null)")
        PROVIDER=$(sanitize "$PROVIDER")
        GENERATION=$(sanitize "$GENERATION")
        [ -z "$EVENT_ID" ] && EVENT_ID=$(sanitize "$GENERATION-$$-$(/bin/date +%s)")

        [ -z "$EVENT" ] && exit 0
        EVENTS="$DIR/$ID.events"
        LOCK="$DIR/$ID.events.lock"
        EVENT_LINE=$(printf \
          '{"schemaVersion":1,"eventID":"%s","provider":"%s","launchGeneration":"%s","hookEventName":"%s","sessionID":"%s","turnID":"%s","model":"%s","permissionMode":"%s"}' \
          "$EVENT_ID" "$PROVIDER" "$GENERATION" "$EVENT" "$SID" "$TURN" "$MODEL" "$PERMISSION")
        export EVENTS EVENT_LINE
        /usr/bin/lockf -s -k "$LOCK" /bin/sh -c \
          'printf "%s\n" "$EVENT_LINE" >> "$EVENTS"' 2>/dev/null || true
        exit 0
        """

    static func install(root: AgentDataRoot) throws {
        try FileManager.default.createDirectory(
            at: root.hooksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let scriptURL = Self.scriptURL(root: root)
        let existing = (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
        if existing != script {
            guard AgentConfig.atomicWrite(Data(script.utf8), to: scriptURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path)
    }

    static func exitEventCommand(
        provider: AgentProviderID,
        agentID: UUID,
        generation: UUID,
        statusDirectory: URL
    ) -> String {
        let eventFormat = "{\"schemaVersion\":1,\"eventID\":\"\(UUID().uuidString)\","
            + "\"provider\":\"\(provider.rawValue)\","
            + "\"launchGeneration\":\"\(generation.uuidString)\","
            + "\"hookEventName\":\"ProviderExited\",\"exitStatus\":%s}"
        let directory = shellQuote(statusDirectory.path)
        let events = shellQuote(
            statusDirectory.appendingPathComponent("\(agentID.uuidString).events").path)
        let lock = shellQuote(
            statusDirectory.appendingPathComponent("\(agentID.uuidString).events.lock").path)
        return "mkdir -p \(directory); EVENT_LINE=$(printf \(shellQuote(eventFormat)) \"$command_status\"); "
            + "export EVENT_LINE; /usr/bin/lockf -s -k \(lock) /bin/sh -c "
            + shellQuote("printf '%s\\n' \"$EVENT_LINE\" >> \(events)")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Mutates a provider JSON settings file while serializing Clawddy writers
    /// and detecting uncoordinated external replacements before committing.
    /// The transform always receives the latest complete object. The file is
    /// written only when the transform changes its content; otherwise nothing
    /// is touched, not even the lock file. Before the first write, the bytes
    /// being replaced are kept at `backupURL` unless a backup already exists.
    /// Returns whether the file was written.
    static func updateJSONFile(
        at url: URL,
        backupURL: URL?,
        transform: (inout [String: Any]) throws -> Void
    ) throws -> Bool {
        guard try pendingChange(at: url, transform: transform) != nil else { return false }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lockURL = url.appendingPathExtension("clawddy.lock")
        if !FileManager.default.fileExists(atPath: lockURL.path) {
            guard FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let lockHandle = try FileHandle(forUpdating: lockURL)
        defer { try? lockHandle.close() }
        guard lockf(lockHandle.fileDescriptor, F_LOCK, 0) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { _ = lockf(lockHandle.fileDescriptor, F_ULOCK, 0) }

        for _ in 0..<3 {
            guard let change = try pendingChange(at: url, transform: transform) else { return false }
            let updated = try JSONSerialization.data(
                withJSONObject: change.object,
                options: [.prettyPrinted, .sortedKeys])

            // An editor that does not participate in our lock may have replaced
            // the file while the transform ran. Retry against that new value.
            if try contents(of: url) != change.before { continue }
            if let before = change.before, let backupURL,
               !FileManager.default.fileExists(atPath: backupURL.path) {
                try before.write(to: backupURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: backupURL.path)
            }
            guard AgentConfig.atomicWrite(updated, to: url) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path)
            return true
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// The file's current bytes and its transformed object, or nil when the
    /// transform leaves the content as it is. A missing file reads as `{}`.
    private static func pendingChange(
        at url: URL,
        transform: (inout [String: Any]) throws -> Void
    ) throws -> (before: Data?, object: [String: Any])? {
        let before = try contents(of: url)
        var object: [String: Any] = [:]
        if let before {
            guard let parsed = try JSONSerialization.jsonObject(with: before) as? [String: Any]
            else { throw CocoaError(.fileReadCorruptFile) }
            object = parsed
        }
        let original = object
        try transform(&object)
        return NSDictionary(dictionary: object).isEqual(to: original) ? nil : (before, object)
    }

    /// The file's bytes, or nil when there is no file. Any other read failure
    /// throws.
    private static func contents(of url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// `hooks` without the handlers that run `root`'s hook script: those whose
    /// command is that script's exact path, quoted as Clawddy writes it, alone
    /// or followed by arguments. Another root's script, a different file in
    /// the same folder, and a command that merely mentions the path are kept.
    /// Groups and events emptied by the removal are dropped; events with
    /// nothing removed are left exactly as they are.
    static func removingHandlers(
        runningScriptOf root: AgentDataRoot,
        from hooks: [String: Any]
    ) -> [String: Any] {
        let script = shellQuote(scriptURL(root: root).path)
        func runsScript(_ handler: [String: Any]) -> Bool {
            guard let command = handler["command"] as? String else { return false }
            return command == script || command.hasPrefix(script + " ")
        }

        var result = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            var removed = false
            let kept = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let keptHandlers = handlers.filter { !runsScript($0) }
                guard keptHandlers.count < handlers.count else { return group }
                removed = true
                guard !keptHandlers.isEmpty else { return nil }
                var group = group
                group["hooks"] = keptHandlers
                return group
            }
            if removed { result[event] = kept.isEmpty ? nil : kept }
        }
        return result
    }
}
