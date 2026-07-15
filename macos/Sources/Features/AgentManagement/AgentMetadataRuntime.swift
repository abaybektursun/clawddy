import Foundation

/// Builds a per-agent Claude settings overlay that captures the official
/// status-line JSON without replacing a user's existing status line.
enum AgentMetadataRuntime {
    struct Preparation: Equatable {
        var settingsURL: URL?
        var unavailableReason: String?
    }

    static var runtimeDirectory: URL { AgentConfig.baseDir.appendingPathComponent("runtime") }
    static var proxyURL: URL { AgentConfig.hooksDir.appendingPathComponent("clawddy-statusline-proxy.sh") }

    static let proxyScript = """
        #!/bin/sh
        umask 077
        ID="$1"
        UPSTREAM_FILE="$2"
        case "$ID" in
          ''|*[!A-Fa-f0-9-]*) cat >/dev/null; exit 0 ;;
        esac

        DIR="${GHOSTTY_AGENT_STATUS_DIR:-$HOME/.config/ghostty-agents/status}"
        mkdir -p "$DIR" 2>/dev/null
        SNAPSHOT="$DIR/$ID.metadata.json"
        TEMP="${TMPDIR:-/tmp}/clawddy-statusline-$ID-$$.json"
        PUBLISH_TEMP="$DIR/$ID.metadata.$$.tmp"
        trap 'rm -f "$TEMP" "$PUBLISH_TEMP"' EXIT HUP INT TERM
        cat > "$TEMP" || exit 0
        chmod 600 "$TEMP" 2>/dev/null
        if [ -d "$DIR" ] && cp "$TEMP" "$PUBLISH_TEMP" 2>/dev/null; then
          chmod 600 "$PUBLISH_TEMP" 2>/dev/null
          mv -f "$PUBLISH_TEMP" "$SNAPSHOT" 2>/dev/null || true
        fi

        if [ -s "$UPSTREAM_FILE" ]; then
          UPSTREAM=$(cat "$UPSTREAM_FILE")
          if [ -n "$UPSTREAM" ]; then
            SHELL_BIN=${SHELL:-/bin/sh}
            "$SHELL_BIN" -lc "$UPSTREAM" < "$TEMP"
            exit $?
          fi
        fi
        exit 0
        """

    static func prepare(agentID: UUID, workingDirectory: String?) -> Preparation {
        do {
            let effective = effectiveSettings(workingDirectory: workingDirectory)
            if effective.managedStatusLine {
                return Preparation(
                    settingsURL: nil,
                    unavailableReason: "Managed Claude settings control the status line.")
            }
            if effective.disableAllHooks {
                return Preparation(
                    settingsURL: nil,
                    unavailableReason: "Claude hooks are disabled by settings.")
            }

            try installProxy()
            let directory = runtimeDirectory.appendingPathComponent(agentID.uuidString)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path)

            let upstreamURL = directory.appendingPathComponent("upstream-statusline.command")
            var upstream = effective.statusLine?["command"] as? String ?? ""
            if upstream.contains(proxyURL.path) { upstream = "" }
            guard AgentConfig.atomicWrite(Data(upstream.utf8), to: upstreamURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: upstreamURL.path)

            var statusLine = effective.statusLine ?? [:]
            statusLine["type"] = "command"
            statusLine["command"] = [
                shellQuote(proxyURL.path),
                shellQuote(agentID.uuidString),
                shellQuote(upstreamURL.path),
            ].joined(separator: " ")

            let overlay: [String: Any] = ["statusLine": statusLine]
            let data = try JSONSerialization.data(
                withJSONObject: overlay,
                options: [.prettyPrinted, .sortedKeys])
            let settingsURL = directory.appendingPathComponent("settings.json")
            guard AgentConfig.atomicWrite(data, to: settingsURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path)
            return Preparation(settingsURL: settingsURL, unavailableReason: nil)
        } catch {
            return Preparation(
                settingsURL: nil,
                unavailableReason: "Session metadata could not be configured.")
        }
    }

    static func remove(agentID: UUID) {
        try? FileManager.default.removeItem(
            at: runtimeDirectory.appendingPathComponent(agentID.uuidString))
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private struct EffectiveSettings {
        var statusLine: [String: Any]?
        var disableAllHooks = false
        var managedStatusLine = false
    }

    private static func effectiveSettings(workingDirectory: String?) -> EffectiveSettings {
        var result = EffectiveSettings()
        let regularURLs = [
            AgentConfig.claudeConfigDir.appendingPathComponent("settings.json"),
            workingDirectory.map {
                URL(fileURLWithPath: $0).appendingPathComponent(".claude/settings.json")
            },
            workingDirectory.map {
                URL(fileURLWithPath: $0).appendingPathComponent(".claude/settings.local.json")
            },
        ].compactMap { $0 }

        for url in regularURLs {
            guard let settings = readObject(url) else { continue }
            if let value = settings["statusLine"] as? [String: Any] {
                result.statusLine = value
            }
            if let value = settings["disableAllHooks"] as? Bool {
                result.disableAllHooks = value
            }
        }

        let managedURLs = [
            URL(fileURLWithPath: "/Library/Application Support/ClaudeCode/managed-settings.json"),
            AgentConfig.claudeConfigDir.appendingPathComponent("managed-settings.json"),
        ]
        for url in managedURLs {
            guard let settings = readObject(url) else { continue }
            if settings["statusLine"] != nil { result.managedStatusLine = true }
            if let value = settings["disableAllHooks"] as? Bool {
                result.disableAllHooks = value
            }
        }
        return result
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func installProxy() throws {
        try FileManager.default.createDirectory(
            at: AgentConfig.hooksDir,
            withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: proxyURL, encoding: .utf8)) ?? ""
        if existing != proxyScript {
            guard AgentConfig.atomicWrite(Data(proxyScript.utf8), to: proxyURL) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: proxyURL.path)
    }
}
