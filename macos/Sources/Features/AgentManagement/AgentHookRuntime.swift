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

    /// How much of each text a record keeps, in bytes: well above
    /// `AgentRecord.textLimit` characters of any width, and far below the
    /// system's limit on one argument.
    static let textBytes = 256 << 10
    /// How much of agy's transcript the script reads, from its end.
    static let transcriptTailBytes = 8 << 20

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
    /// other event. For agy it prints `{}`, whatever happens, an incomplete
    /// identity included.
    ///
    /// agy's last reply is not in its payload: the script reads the last
    /// `transcriptTailBytes` of the transcript file the payload names (`~/`
    /// taken as the home folder), one JSON object per line, from its end
    /// back to the turn's prompt (`USER_INPUT`), and takes the last
    /// `PLANNER_RESPONSE` with content. A line that is not complete JSON
    /// (the file cut short, or the tail's first line) ends the search with
    /// no text, so the report's message stands; a transcript named that
    /// cannot be read is a hook failure.
    ///
    /// Text (a prompt, a message, an error's text, a question) goes into the
    /// record without the shell ever parsing it: `plutil` reads the raw value
    /// out of the payload, the value travels as one argument into a fresh
    /// property list, and `plutil` writes that list as JSON. The `x` after
    /// the value keeps its trailing newlines, which `$(...)` would drop; the
    /// one newline `raw` adds goes with the `x`. A payload without the field
    /// records no text, never an empty one. Each text is cut to
    /// `textBytes` on a character boundary, so no argument nears the
    /// system's limit, and the record reaches the event file through a file,
    /// never an argument or the environment.
    ///
    /// At agy's PreInvocation the script also records the type of the
    /// transcript's last step at that moment (`step`, read from the same
    /// bounded tail): `USER_INPUT` for a prompt the person sent, another
    /// type when agy started the invocation itself (after a background
    /// command ended). A transcript that cannot be read then records no
    /// step and a line in `hook-errors.log`, and the prompt still counts.
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
        case "$PROVIDER" in
          \(AgentProviderID.antigravity.rawValue)) printf '%s\n' '\(AntigravityProvider.hookReply)' ;;
        esac
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

        log_error() {
          LOG="$DIR/hook-errors.log"
          SIZE=$(/usr/bin/stat -f %z "$LOG" 2>/dev/null) || SIZE=0
          if [ "$SIZE" -gt 65536 ]; then
            /bin/mv -f "$LOG" "$LOG.1" 2>/dev/null
          fi
          printf '%s %s %s %s: %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$PROVIDER" "$ID" "${EVENT:-?}" "$1" >> "$LOG" 2>/dev/null
        }
        fail() {
          log_error "$1"
          # The agent shows that a report was lost, when its file takes a line.
          printf '\n{"schemaVersion":1,"provider":"%s","launchGeneration":"%s","hookEventName":"\(failureRecordName)","text":"%s"}\n' \
            "$PROVIDER" "$GENERATION" "$(printf '%s' "${EVENT:-?}: $1" | /usr/bin/tr -cd '[:alnum:] _.:/-')" \
            >> "$DIR/$ID.events" 2>/dev/null
          exit 0
        }

        INPUT=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/clawddy-hook.XXXXXX") || fail "could not make a temporary file"
        TEXTS=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/clawddy-hook.XXXXXX") || fail "could not make a temporary file"
        TAIL=
        STEPS=
        trap 'rm -f "$INPUT" "$TEXTS" ${TAIL:+"$TAIL"} ${STEPS:+"$STEPS"}' EXIT HUP INT TERM
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
          case "$PROVIDER" in
            \(AgentProviderID.antigravity.rawValue))
              EVENT_KEY=\(AntigravityProvider.eventField)
              SESSION_KEY=\(AntigravityProvider.sessionField)
              ;;
            *)
              EVENT_KEY=hook_event_name
              SESSION_KEY=session_id
              ;;
          esac
        fi
        chmod 600 "$INPUT" 2>/dev/null

        extract() {
          /usr/bin/plutil -extract "$1" raw -o - "$INPUT" 2>/dev/null || true
        }
        sanitize() {
          printf '%s' "$1" | /usr/bin/tr -cd '[:alnum:]_.:/-'
        }
        # VALUE cut to its first \(textBytes) bytes, on a character boundary.
        # Its length counted in bytes: in a UTF-8 locale ${#VALUE} counts
        # characters, up to four bytes each.
        bound() {
          [ "$(LC_ALL=C; printf '%s' "${#VALUE}")" -gt \(textBytes) ] || return 0
          VALUE=$(printf '%s' "$VALUE" | /usr/bin/head -c \(textBytes) | /usr/bin/iconv -c -f UTF-8 -t UTF-8 2>/dev/null; printf x)
          VALUE=${VALUE%x}
        }
        # The field's raw text, trailing newlines kept, in VALUE; false when
        # the payload has no such field.
        text() {
          VALUE=$(/usr/bin/plutil -extract "$1" raw -o - "$INPUT" 2>/dev/null && printf x)
          [ -n "$VALUE" ] || return 1
          VALUE=${VALUE%?x}
          bound
        }
        # The transcript file the field names, `~/` taken as the home folder.
        transcript() {
          TRANSCRIPT=$(extract "$1")
          case "$TRANSCRIPT" in
            "~/"*) TRANSCRIPT="$HOME/${TRANSCRIPT#??}" ;;
          esac
        }
        # The type of the last step of the transcript the field names, in
        # STEP; empty when none is named or it cannot be read. Blank lines,
        # such as one the file ends with, are no step.
        last_step() {
          transcript "$1"
          [ -n "$TRANSCRIPT" ] || return 0
          if [ -r "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
            STEP=$(sanitize "$(/usr/bin/tail -c \(transcriptTailBytes) "$TRANSCRIPT" \
              | /usr/bin/awk 'NF { line = $0 } END { printf "%s", line }' \
              | /usr/bin/plutil -extract type raw -o - - 2>/dev/null)")
          else
            log_error "could not read the transcript $TRANSCRIPT; the prompt is recorded"
          fi
        }
        # The last reply in the transcript the field names, in VALUE; false
        # when the turn has none.
        reply() {
          transcript "$1"
          [ -n "$TRANSCRIPT" ] || return 1
          [ -r "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || fail "could not read the transcript $TRANSCRIPT"
          TAIL=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/clawddy-hook.XXXXXX") || fail "could not make a temporary file"
          STEPS=$(/usr/bin/mktemp "${TMPDIR:-/tmp}/clawddy-hook.XXXXXX") || fail "could not make a temporary file"
          /usr/bin/tail -c \(transcriptTailBytes) "$TRANSCRIPT" > "$TAIL" || fail "could not read $TRANSCRIPT"
          # A last line without its newline would be joined to the one before.
          [ -z "$(/usr/bin/tail -c 1 "$TAIL")" ] || echo >> "$TAIL"
          /usr/bin/tail -r "$TAIL" > "$STEPS" || fail "could not read $TRANSCRIPT"
          while IFS= read -r LINE; do
            # A blank line, such as one the file ends with, is no step.
            [ -n "$LINE" ] || continue
            TYPE=$(printf '%s' "$LINE" | /usr/bin/plutil -extract type raw -o - - 2>/dev/null) || return 1
            case "$TYPE" in
              USER_INPUT) return 1 ;;
              PLANNER_RESPONSE)
                VALUE=$(printf '%s' "$LINE" | /usr/bin/plutil -extract content raw -o - - 2>/dev/null && printf x)
                VALUE=${VALUE%?x}
                if [ -n "$VALUE" ]; then
                  bound
                  return 0
                fi
                ;;
            esac
          done < "$STEPS"
          return 1
        }

        SID=$(sanitize "$(extract "$SESSION_KEY")")
        EVENT=$(sanitize "$(extract "$EVENT_KEY")")
        MODEL=$(sanitize "$(extract model)")
        PERMISSION=$(sanitize "$(extract permission_mode)")
        TRIGGER=$(sanitize "$(extract trigger)")
        # A failure's error: Claude's kind, or agy's own words, bounded and
        # with its spaces, so its words stay apart (agy's quota rule).
        ERROR=$(extract error | /usr/bin/head -c 65536)
        ERROR=$(printf '%s' "$ERROR" | LC_ALL=C /usr/bin/tr '\\n\\t\\r' '   ' | LC_ALL=C /usr/bin/tr -cd '[:alnum:] _.:/=-' | /usr/bin/head -c 4096)
        REASON=$(sanitize "$(extract reason)")
        SOURCE=$(sanitize "$(extract source)")
        EVENT_ID=$(sanitize "$(/usr/bin/uuidgen 2>/dev/null)")
        [ -z "$EVENT_ID" ] && EVENT_ID=$(sanitize "$GENERATION-$$-$(/bin/date +%s)")

        [ -z "$EVENT" ] && fail "the hook input names no $EVENT_KEY"
        TEXT_FIELD=
        TRANSCRIPT_FIELD=
        STEP_FIELD=
        case "$PROVIDER" in
        \(providerCase(.claudeCode, turnIDField: ClaudeCodeProvider.turnIDField, events: ClaudeCodeProvider.hookEvents, textFields: ClaudeCodeProvider.textFields))
        \(providerCase(.codex, turnIDField: CodexProvider.turnIDField, events: CodexProvider.hookEvents, textFields: CodexProvider.textFields, promptsField: CodexProvider.promptsField))
        \(providerCase(.antigravity, invocationField: AntigravityProvider.invocationField, events: AntigravityProvider.hookEvents, textFields: AntigravityProvider.textFields, transcriptFields: AntigravityProvider.transcriptFields, stepFields: AntigravityProvider.stepFields))
          *) fail "unknown provider $PROVIDER" ;;
        esac
        TURN=
        [ -n "$TURN_FIELD" ] && TURN=$(sanitize "$(extract "$TURN_FIELD")")
        INVOCATION=
        [ -n "$INVOCATION_FIELD" ] && INVOCATION=$(sanitize "$(extract "$INVOCATION_FIELD")")
        STEP=
        # Only an invocation that starts a turn can be a prompt.
        [ -n "$STEP_FIELD" ] && [ "$INVOCATION" = 0 ] && last_step "$STEP_FIELD"
        EVENTS="$DIR/$ID.events"
        LOCK="$DIR/$ID.events.lock"
        EVENT_LINE=$(printf \
          '{"schemaVersion":1,"eventID":"%s","provider":"%s","launchGeneration":"%s","hookEventName":"%s","sessionID":"%s","turnID":"%s","invocation":"%s","step":"%s","model":"%s","permissionMode":"%s","trigger":"%s","error":"%s","reason":"%s","source":"%s"}' \
          "$EVENT_ID" "$PROVIDER" "$GENERATION" "$EVENT" "$SID" "$TURN" "$INVOCATION" "$STEP" "$MODEL" "$PERMISSION" "$TRIGGER" "$ERROR" "$REASON" "$SOURCE")

        if [ -n "$TEXT_FIELD$PROMPTS_FIELD$TRANSCRIPT_FIELD" ]; then
          printf '%s' '<plist version="1.0"><dict/></plist>' > "$TEXTS" || fail "could not write $TEXTS"
          if [ -n "$TEXT_FIELD" ] && text "$TEXT_FIELD"; then
            /usr/bin/plutil -insert text -string "$VALUE" "$TEXTS" || fail "could not record $TEXT_FIELD"
          fi
          if [ -n "$TRANSCRIPT_FIELD" ] && reply "$TRANSCRIPT_FIELD"; then
            /usr/bin/plutil -insert text -string "$VALUE" "$TEXTS" || fail "could not record the reply in $TRANSCRIPT"
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

        printf '\n%s\n' "$EVENT_LINE" > "$TEXTS" || fail "could not write $TEXTS"
        /usr/bin/lockf -s -k "$LOCK" /usr/bin/tee -a "$EVENTS" < "$TEXTS" > /dev/null 2>&1 \
          || fail "could not append to $EVENTS (status $?)"
        exit 0
        """

    /// One provider's part of the script, made from its event table: the
    /// payload fields that name its turn and its invocation, the hook events
    /// it records, the field whose text each event carries, the field naming
    /// the transcript whose last reply an event carries, the field naming
    /// the transcript whose last step's type an event records, and the field
    /// holding a list of prompts.
    private static func providerCase(
        _ provider: AgentProviderID,
        turnIDField: String? = nil,
        invocationField: String? = nil,
        events: [String: AgentProviderEntry.Meaning],
        textFields: [String: String],
        transcriptFields: [String: String] = [:],
        stepFields: [String: String] = [:],
        promptsField: String? = nil
    ) -> String {
        let textCases = Set(textFields.keys).union(transcriptFields.keys).union(stepFields.keys).sorted().map { event in
            let fields = [
                textFields[event].map { "TEXT_FIELD=\($0)" }, transcriptFields[event].map { "TRANSCRIPT_FIELD=\($0)" },
                stepFields[event].map { "STEP_FIELD=\($0)" },
            ]
            return "      \(event)) \(fields.compactMap { $0 }.joined(separator: " ")) ;;"
        }.joined(separator: "\n")
        return """
          \(provider.rawValue))
            TURN_FIELD=\(turnIDField ?? "")
            INVOCATION_FIELD=\(invocationField ?? "")
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
