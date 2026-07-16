import Foundation

enum AgentHookRuntime {
    static var scriptURL: URL {
        AgentConfig.hooksDir.appendingPathComponent("clawddy-provider-hook.sh")
    }

    static let script = """
        #!/bin/sh
        umask 077
        ID="${GHOSTTY_AGENT_ID:-$GHOSTTY_AGENT_NAME}"
        if [ -z "$ID" ]; then
          cat >/dev/null
          exit 0
        fi

        DIR="${GHOSTTY_AGENT_STATUS_DIR:-$HOME/.config/ghostty-agents/status}"
        PROVIDER="${GHOSTTY_AGENT_PROVIDER:-claudeCode}"
        GENERATION="${GHOSTTY_AGENT_LAUNCH_GENERATION:-}"
        mkdir -p "$DIR" 2>/dev/null || exit 0

        INPUT="${TMPDIR:-/tmp}/clawddy-hook-$ID-$$.json"
        SESSION_TEMP="$DIR/$ID.session.$$.tmp"
        trap 'rm -f "$INPUT" "$SESSION_TEMP"' EXIT HUP INT TERM
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

        if [ -n "$SID" ]; then
          printf '{"provider":"%s","sessionID":"%s","launchGeneration":"%s"}\n' \
            "$PROVIDER" "$SID" "$GENERATION" > "$SESSION_TEMP"
          chmod 600 "$SESSION_TEMP" 2>/dev/null
          mv -f "$SESSION_TEMP" "$DIR/$ID.session.json" 2>/dev/null || true
        fi

        [ -z "$EVENT" ] && exit 0
        EVENTS="$DIR/$ID.events"
        LOCK="$DIR/$ID.events.lock"
        EVENT_LINE=$(printf \
          '{"schemaVersion":1,"eventID":"%s","provider":"%s","launchGeneration":"%s","hookEventName":"%s","sessionID":"%s","turnID":"%s","model":"%s","permissionMode":"%s"}' \
          "$EVENT_ID" "$PROVIDER" "$GENERATION" "$EVENT" "$SID" "$TURN" "$MODEL" "$PERMISSION")
        export EVENTS EVENT_LINE
        /usr/bin/lockf -s -t 5 -k "$LOCK" /bin/sh -c \
          'printf "%s\n" "$EVENT_LINE" >> "$EVENTS"' 2>/dev/null || true
        exit 0
        """

    static func install() throws {
        try FileManager.default.createDirectory(
            at: AgentConfig.hooksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
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
        statusDirectory: URL = AgentConfig.statusDir
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
            + "export EVENT_LINE; /usr/bin/lockf -s -t 5 -k \(lock) /bin/sh -c "
            + shellQuote("printf '%s\\n' \"$EVENT_LINE\" >> \(events)")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Mutates a provider JSON settings file while serializing Clawddy writers
    /// and detecting uncoordinated external replacements before committing.
    /// The transform always receives the latest complete object.
    static func updateJSONFile(
        at url: URL,
        backupURL: URL?,
        transform: (inout [String: Any]) throws -> Void
    ) throws -> Bool {
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
            let before = try? Data(contentsOf: url)
            var root: [String: Any] = [:]
            if let before {
                guard let object = try JSONSerialization.jsonObject(with: before)
                    as? [String: Any]
                else { throw CocoaError(.fileReadCorruptFile) }
                root = object
                if let backupURL,
                   !FileManager.default.fileExists(atPath: backupURL.path) {
                    try before.write(to: backupURL, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: backupURL.path)
                }
            }

            try transform(&root)
            let updated = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys])
            if before == updated {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path)
                return false
            }

            // An editor that does not participate in our lock may have replaced
            // the file while the transform ran. Retry against that new value.
            if (try? Data(contentsOf: url)) != before { continue }
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

    static func removingIntegrationHandlers(from hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for key in hooks.keys {
            guard let groups = hooks[key] as? [[String: Any]] else { continue }
            let filteredGroups = groups.compactMap { original -> [String: Any]? in
                guard let handlers = original["hooks"] as? [[String: Any]] else {
                    return original
                }
                let filteredHandlers = handlers.filter { handler in
                    (handler["command"] as? String)?.contains("ghostty-agents/hooks/") != true
                }
                guard !filteredHandlers.isEmpty else { return nil }
                var group = original
                group["hooks"] = filteredHandlers
                return group
            }
            result[key] = filteredGroups.isEmpty ? nil : filteredGroups
        }
        return result
    }
}
