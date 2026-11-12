import Foundation
import os

private let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "AgentMetadata")

/// Builds a per-agent Claude settings overlay that carries the agent's hooks
/// and captures the official status-line JSON without replacing a user's
/// existing status line.
enum AgentMetadataRuntime {
    struct Preparation: Equatable {
        var settingsURL: URL?
        var unavailableReason: String?
    }

    static func proxyURL(root: AgentDataRoot) -> URL {
        root.hooksDir.appendingPathComponent("clawddy-statusline-proxy.sh")
    }

    /// The status-line command Claude runs. The status folder travels as the
    /// proxy's first argument; the proxy has no default.
    static func statusLineCommand(root: AgentDataRoot, agentID: UUID, upstreamURL: URL) -> String {
        [proxyURL(root: root).path, root.statusDir.path, agentID.uuidString, upstreamURL.path]
            .map(shellQuote)
            .joined(separator: " ")
    }

    /// Arguments: status folder, agent ID, and the file holding the user's own
    /// status-line command.
    static let proxyScript = """
        #!/bin/sh
        umask 077
        DIR="$1"
        ID="$2"
        UPSTREAM_FILE="$3"
        if [ -z "$DIR" ]; then
          cat >/dev/null
          echo "clawddy-statusline-proxy.sh: missing status folder argument" >&2
          exit 1
        fi
        case "$ID" in
          ''|*[!A-Fa-f0-9-]*) cat >/dev/null; exit 0 ;;
        esac

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

    /// Writes the agent's settings overlay: `hooks` always, and the status-line
    /// proxy unless managed settings own the status line. No overlay is
    /// written when settings disable all hooks, which also disables the
    /// status line.
    static func prepare(
        agentID: UUID,
        workingDirectory: String?,
        root: AgentDataRoot,
        hooks: [String: Any]
    ) -> Preparation {
        do {
            let effective = effectiveSettings(workingDirectory: workingDirectory)
            if effective.disableAllHooks {
                return Preparation(
                    settingsURL: nil,
                    unavailableReason: "Claude hooks are disabled by settings.")
            }

            let directory = root.runtimeDir.appendingPathComponent(agentID.uuidString)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path)

            var overlay: [String: Any] = ["hooks": hooks]
            var unavailableReason: String?
            if effective.managedStatusLine {
                unavailableReason = "Managed Claude settings control the status line."
            } else {
                try installProxy(root: root)
                let proxyURL = Self.proxyURL(root: root)
                let upstreamURL = directory.appendingPathComponent("upstream-statusline.command")
                var upstream = effective.statusLine?["command"] as? String ?? ""
                if upstream.contains(proxyURL.path) { upstream = "" }
                try AgentConfig.atomicWrite(Data(upstream.utf8), to: upstreamURL)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: upstreamURL.path)

                var statusLine = effective.statusLine ?? [:]
                statusLine["type"] = "command"
                statusLine["command"] = statusLineCommand(
                    root: root,
                    agentID: agentID,
                    upstreamURL: upstreamURL)
                overlay["statusLine"] = statusLine
            }

            let data = try JSONSerialization.data(
                withJSONObject: overlay,
                options: [.prettyPrinted, .sortedKeys])
            let settingsURL = directory.appendingPathComponent("settings.json")
            try AgentConfig.atomicWrite(data, to: settingsURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path)
            return Preparation(settingsURL: settingsURL, unavailableReason: unavailableReason)
        } catch {
            return Preparation(
                settingsURL: nil,
                unavailableReason: "Session settings could not be written: \(error.localizedDescription)")
        }
    }

    static func remove(agentID: UUID, root: AgentDataRoot) throws {
        try FileManager.default.removeItemIfPresent(
            at: root.runtimeDir.appendingPathComponent(agentID.uuidString))
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

    /// The settings object in `url`, or nil when there is no such file. A
    /// file that cannot be read or parsed is logged with its path and left
    /// out: one broken settings file of the user's must not keep the agent's
    /// own hooks from being installed.
    private static func readObject(_ url: URL) -> [String: Any]? {
        do {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let settings = object as? [String: Any] else {
                logger.error("ignored \(url.path, privacy: .public): not a JSON object")
                return nil
            }
            return settings
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            logger.error("ignored \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func installProxy(root: AgentDataRoot) throws {
        try FileManager.default.createDirectory(
            at: root.hooksDir,
            withIntermediateDirectories: true)
        let proxyURL = Self.proxyURL(root: root)
        if try AgentHookRuntime.text(of: proxyURL) != proxyScript {
            try AgentConfig.atomicWrite(Data(proxyScript.utf8), to: proxyURL)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: proxyURL.path)
    }
}
