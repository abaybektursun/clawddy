import Foundation

enum AgentHookRuntime {
    static func scriptURL(root: AgentDataRoot) -> URL {
        root.hooksDir.appendingPathComponent("clawddy-provider-hook.sh")
    }

    /// A Claude agent's hook command, written into its own settings overlay:
    /// the script, the status folder and the agent's identity as arguments.
    static func command(
        root: AgentDataRoot,
        provider: AgentProviderID,
        agentID: UUID,
        generation: UUID
    ) -> String {
        arguments(root: root, provider: provider, agentID: agentID, generation: generation)
            .map(shellQuote)
            .joined(separator: " ")
    }

    /// The script and its four arguments, unquoted: a Codex launch's notify
    /// program is this list.
    static func arguments(
        root: AgentDataRoot,
        provider: AgentProviderID,
        agentID: UUID,
        generation: UUID
    ) -> [String] {
        [scriptURL(root: root).path, root.statusDir.path, provider.rawValue, agentID.uuidString, generation.uuidString]
    }

    /// The record the script appends when it could not record an event.
    static let failureRecordName = "HookFailed"

    /// The fifth argument that makes the script Codex's notify program.
    static let notifyMode = "notify"

    /// Arguments: STATUS_DIR PROVIDER AGENT_ID GENERATION, then for Codex's
    /// notify program `notify`, the owner's own notify command (any number
    /// of words, possibly none) and the payload Codex appends as the last
    /// argument. A hook reads its payload from its input. Without a complete
    /// identity the script drains its input and records nothing; it exits 0,
    /// because an argument-less global entry left by an older Clawddy must not
    /// report a hook error in every session on the machine. The script only
    /// appends records; the bridge writes the session binding from them. It
    /// records only the events of the provider's event table, each with the
    /// turn named by the payload field that table gives, and nothing for any
    /// other event.
    ///
    /// Text (a prompt, a message, an error's text, a question) goes into the
    /// record without the shell ever parsing it: `plutil` reads the raw value
    /// out of the payload, the value travels as one argument into a fresh
    /// property list, and `plutil` writes that list as JSON. The `x` after
    /// the value keeps its trailing newlines, which `$(...)` would drop; the
    /// one newline `raw` adds goes with the `x`. A payload without the field
    /// records no text, never an empty one.
    ///
    /// A hook that has an identity but cannot record its event appends one
    /// line saying why to `hook-errors.log` in the status folder, and still
    /// exits 0. Once that log passes 64 KiB it becomes `hook-errors.log.1`,
    /// replacing the previous one, so the two stay near 128 KiB at most.
    static let script = """
        #!/bin/sh
        umask 077
        DIR="$1"
        PROVIDER=$(printf '%s' "$2" | /usr/bin/tr -cd '[:alnum:]')
        ID=$(printf '%s' "$3" | /usr/bin/tr -cd 'A-Fa-f0-9-')
        GENERATION=$(printf '%s' "$4" | /usr/bin/tr -cd 'A-Fa-f0-9-')
        if [ -z "$DIR" ] || [ -z "$PROVIDER" ] || [ -z "$ID" ] || [ -z "$GENERATION" ]; then
          cat >/dev/null
          exit 0
        fi

        if ! mkdir -p "$DIR" 2>/dev/null; then
          echo "clawddy-provider-hook.sh: cannot create $DIR" >&2
          exit 0
        fi

        fail() {
          LOG="$DIR/hook-errors.log"
          SIZE=$(/usr/bin/stat -f %z "$LOG" 2>/dev/null) || SIZE=0
          if [ "$SIZE" -gt 65536 ]; then
            /bin/mv -f "$LOG" "$LOG.1" 2>/dev/null
          fi
          printf '%s %s %s %s: %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$PROVIDER" "$ID" "${EVENT:-?}" "$1" >> "$LOG" 2>/dev/null
          # The agent shows that a report was lost, when its file takes a line.
          printf '\n{"schemaVersion":1,"provider":"%s","launchGeneration":"%s","hookEventName":"\(failureRecordName)","text":"%s"}\n' \
            "$PROVIDER" "$GENERATION" "$(printf '%s' "${EVENT:-?}: $1" | /usr/bin/tr -cd '[:alnum:] _.:/-')" \
            >> "$DIR/$ID.events" 2>/dev/null
          exit 0
        }

        INPUT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/clawddy-hook.XXXXXX") || fail "could not make a temporary file"
        TEXTS=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/clawddy-hook.XXXXXX") || fail "could not make a temporary file"
        trap 'rm -f "$INPUT" "$TEXTS"' EXIT HUP INT TERM
        if [ "${5:-}" = \(notifyMode) ]; then
          # Codex's notify program. The payload is the last argument; the
          # words between `notify` and it are the owner's own notify command,
          # which runs as Codex would have run it.
          for PAYLOAD; do :; done
          shift 5
          if [ "$#" -gt 1 ]; then
            ( "$@" </dev/null >/dev/null 2>&1 & )
          fi
          printf '%s' "$PAYLOAD" > "$INPUT" || fail "could not save the notify payload to $INPUT"
          EVENT_KEY=type
          SESSION_KEY=thread-id
        else
          cat > "$INPUT" || fail "could not save the hook input to $INPUT"
          EVENT_KEY=hook_event_name
          SESSION_KEY=session_id
        fi
        chmod 600 "$INPUT" 2>/dev/null

        extract() {
          /usr/bin/plutil -extract "$1" raw -o - "$INPUT" 2>/dev/null || true
        }
        sanitize() {
          printf '%s' "$1" | /usr/bin/tr -cd '[:alnum:]_.:/-'
        }
        # The field's raw text, trailing newlines kept, in VALUE; false when
        # the payload has no such field.
        text() {
          VALUE=$(/usr/bin/plutil -extract "$1" raw -o - "$INPUT" 2>/dev/null && printf x)
          [ -n "$VALUE" ] || return 1
          VALUE=${VALUE%?x}
        }

        SID=$(sanitize "$(extract "$SESSION_KEY")")
        EVENT=$(sanitize "$(extract "$EVENT_KEY")")
        MODEL=$(sanitize "$(extract model)")
        PERMISSION=$(sanitize "$(extract permission_mode)")
        TRIGGER=$(sanitize "$(extract trigger)")
        ERROR=$(sanitize "$(extract error)")
        REASON=$(sanitize "$(extract reason)")
        SOURCE=$(sanitize "$(extract source)")
        EVENT_ID=$(sanitize "$(/usr/bin/uuidgen 2>/dev/null)")
        [ -z "$EVENT_ID" ] && EVENT_ID=$(sanitize "$GENERATION-$$-$(/bin/date +%s)")

        [ -z "$EVENT" ] && fail "the hook input names no $EVENT_KEY"
        TEXT_FIELD=
        PROMPTS_FIELD=
        case "$PROVIDER" in
        \(providerCase(.claudeCode, turnIDField: ClaudeCodeProvider.turnIDField, events: ClaudeCodeProvider.hookEvents, textFields: ClaudeCodeProvider.textFields))
        \(providerCase(.codex, turnIDField: CodexProvider.turnIDField, events: CodexProvider.hookEvents, textFields: CodexProvider.textFields, promptsField: CodexProvider.promptsField))
          *) fail "unknown provider $PROVIDER" ;;
        esac
        TURN=$(sanitize "$(extract "$TURN_FIELD")")
        EVENTS="$DIR/$ID.events"
        LOCK="$DIR/$ID.events.lock"
        EVENT_LINE=$(printf \
          '{"schemaVersion":1,"eventID":"%s","provider":"%s","launchGeneration":"%s","hookEventName":"%s","sessionID":"%s","turnID":"%s","model":"%s","permissionMode":"%s","trigger":"%s","error":"%s","reason":"%s","source":"%s"}' \
          "$EVENT_ID" "$PROVIDER" "$GENERATION" "$EVENT" "$SID" "$TURN" "$MODEL" "$PERMISSION" "$TRIGGER" "$ERROR" "$REASON" "$SOURCE")

        if [ -n "$TEXT_FIELD$PROMPTS_FIELD" ]; then
          printf '%s' '<plist version="1.0"><dict/></plist>' > "$TEXTS" || fail "could not write $TEXTS"
          if [ -n "$TEXT_FIELD" ] && text "$TEXT_FIELD"; then
            /usr/bin/plutil -insert text -string "$VALUE" "$TEXTS" || fail "could not record $TEXT_FIELD"
          fi
          if [ -n "$PROMPTS_FIELD" ]; then
            COUNT=$(extract "$PROMPTS_FIELD")
            case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac
            I=0
            while [ "$I" -lt "$COUNT" ]; do
              text "$PROMPTS_FIELD.$I" || VALUE=
              if [ "$I" -eq 0 ]; then
                /usr/bin/plutil -insert prompts -array "$TEXTS" || fail "could not record $PROMPTS_FIELD"
              fi
              /usr/bin/plutil -insert prompts -string "$VALUE" -append "$TEXTS" || fail "could not record $PROMPTS_FIELD.$I"
              I=$((I + 1))
            done
          fi
          JSON=$(/usr/bin/plutil -convert json -o - "$TEXTS") || fail "could not convert $TEXTS"
          case "$JSON" in
            '{}') ;;
            *) EVENT_LINE="${EVENT_LINE%\\}},${JSON#\\{}" ;;
          esac
        fi

        export EVENTS EVENT_LINE
        /usr/bin/lockf -s -k "$LOCK" /bin/sh -c \
          'printf "\n%s\n" "$EVENT_LINE" >> "$EVENTS"' 2>/dev/null \
          || fail "could not append to $EVENTS (status $?)"
        exit 0
        """

    /// One provider's part of the script, made from its event table: the
    /// payload field that names its turn, the hook events it records, the
    /// field whose text each event carries, and the field holding a list of
    /// prompts.
    private static func providerCase(
        _ provider: AgentProviderID,
        turnIDField: String,
        events: [String: AgentProviderEntry.Meaning],
        textFields: [String: String],
        promptsField: String? = nil
    ) -> String {
        let textCases = textFields.keys.sorted().map { event in
            "      \(event)) TEXT_FIELD=\(textFields[event] ?? "") ;;"
        }.joined(separator: "\n")
        return """
          \(provider.rawValue))
            TURN_FIELD=\(turnIDField)
            PROMPTS_FIELD=\(promptsField ?? "")
            case "$EVENT" in
              \(events.keys.sorted().joined(separator: "|"))) ;;
              *) exit 0 ;;
            esac
            case "$EVENT" in
        \(textCases)
              *) ;;
            esac
            ;;
        """
    }

    static func install(root: AgentDataRoot) throws {
        try FileManager.default.createDirectory(
            at: root.hooksDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let scriptURL = Self.scriptURL(root: root)
        if try text(of: scriptURL) != script {
            try AgentConfig.atomicWrite(Data(script.utf8), to: scriptURL)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path)
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// The file's text, or nil when there is no file. Any other read
    /// failure throws.
    static func text(of url: URL) throws -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
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
        // The handle closes its descriptor when it is released.
        let lockHandle = try FileHandle(forUpdating: lockURL)
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
            try AgentConfig.atomicWrite(updated, to: url)
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
