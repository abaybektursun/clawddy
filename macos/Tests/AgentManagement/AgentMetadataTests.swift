import Foundation
import Testing
@testable import Ghostty

struct AgentMetadataTests {
    @Test func decodesOfficialStatusLineFieldsAndComputesInputContext() throws {
        let payload = Data("""
            {
              "session_id": "session-123",
              "session_name": "metadata-test",
              "transcript_path": "/tmp/transcript.jsonl",
              "version": "2.1.209",
              "model": {"id": "claude-opus-4-8", "display_name": "Opus 4.8"},
              "effort": {"level": "xhigh"},
              "thinking": {"enabled": true},
              "context_window": {
                "context_window_size": 200000,
                "used_percentage": 64.25,
                "remaining_percentage": 35.75,
                "total_input_tokens": 180000,
                "total_output_tokens": 12000,
                "current_usage": {
                  "input_tokens": 80000,
                  "output_tokens": 9000,
                  "cache_creation_input_tokens": 20000,
                  "cache_read_input_tokens": 28500
                }
              },
              "cost": {
                "total_cost_usd": 3.75,
                "total_duration_ms": 90000,
                "total_api_duration_ms": 30000,
                "total_lines_added": 20,
                "total_lines_removed": 4
              }
            }
            """.utf8)
        let observedAt = Date(timeIntervalSince1970: 123)

        let metadata = try AgentSessionMetadata.decodeStatusLinePayload(
            payload,
            observedAt: observedAt)

        #expect(metadata.modelID == "claude-opus-4-8")
        #expect(metadata.displayModel == "Opus 4.8")
        #expect(metadata.displayEffort == "Extra high")
        #expect(metadata.contextUsedTokens == 128_500)
        #expect(metadata.contextFraction == 0.6425)
        #expect(metadata.contextPercentText == "64%")
        #expect(metadata.currentOutputTokens == 9_000)
        #expect(metadata.totalCostUSD == 3.75)
        #expect(metadata.observedAt == observedAt)
    }

    @Test func acceptsPreResponseNullContextWithoutInventingZero() throws {
        let payload = Data("""
            {
              "model": {"id": "claude-sonnet-4-6", "display_name": "Sonnet 4.6"},
              "effort": {"level": "high"},
              "context_window": {
                "context_window_size": 200000,
                "used_percentage": null,
                "remaining_percentage": null,
                "current_usage": null
              }
            }
            """.utf8)

        let metadata = try AgentSessionMetadata.decodeStatusLinePayload(payload)

        #expect(metadata.displayModel == "Sonnet 4.6")
        #expect(metadata.displayEffort == "High")
        #expect(metadata.contextUsedTokens == nil)
        #expect(metadata.contextFraction == nil)
        #expect(metadata.contextPercentText == nil)
    }

    @MainActor
    @Test func metadataFreshnessTracksAuthoritativeLifecycle() {
        let agent = AgentInstance(entry: AgentEntry(name: "Metadata"))
        #expect(agent.metadataIsHistorical)

        agent.surfaceState = .open
        agent.processState = .running
        agent.metadataAvailability = .available
        #expect(!agent.metadataIsHistorical)

        agent.metadataAvailability = .waiting
        #expect(agent.metadataIsHistorical)
    }

    @Test func proxyHasValidPOSIXShellSyntax() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(AgentMetadataRuntime.proxyScript.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test func proxyPublishesExactPayloadAndPreservesUpstreamOutput() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("clawddy-metadata-tests-\(UUID().uuidString)")
        let status = root.appendingPathComponent(".config/ghostty-agents/status")
        let script = root.appendingPathComponent("proxy.sh")
        let upstream = root.appendingPathComponent("upstream.command")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: status, withIntermediateDirectories: true)
        try AgentMetadataRuntime.proxyScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "cat".write(to: upstream, atomically: true, encoding: .utf8)

        let id = UUID()
        let payload = Data("{\"model\":{\"id\":\"claude-opus-4-8\"}}\n".utf8)
        let output = try runProxy(
            script: script,
            agentID: id,
            upstream: upstream,
            home: root,
            payload: payload)

        #expect(output.status == 0)
        #expect(output.stdout == payload)
        #expect(try Data(contentsOf: status.appendingPathComponent("\(id.uuidString).metadata.json")) == payload)
        let attributes = try fm.attributesOfItem(
            atPath: status.appendingPathComponent("\(id.uuidString).metadata.json").path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func proxyStillRunsUpstreamWhenPublicationFails() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("clawddy-metadata-tests-\(UUID().uuidString)")
        let blockedStatus = root.appendingPathComponent(".config/ghostty-agents/status")
        let script = root.appendingPathComponent("proxy.sh")
        let upstream = root.appendingPathComponent("upstream.command")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: blockedStatus.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blockedStatus)
        try AgentMetadataRuntime.proxyScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "cat".write(to: upstream, atomically: true, encoding: .utf8)
        let payload = Data("{\"model\":null}\n".utf8)

        let output = try runProxy(
            script: script,
            agentID: UUID(),
            upstream: upstream,
            home: root,
            payload: payload)

        #expect(output.status == 0)
        #expect(output.stdout == payload)
    }

    @Test func explicitStatusDirectoryIsIndependentFromHome() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("clawddy-metadata-tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent("account-home")
        let isolatedStatus = root.appendingPathComponent("isolated/status")
        let script = root.appendingPathComponent("proxy.sh")
        let upstream = root.appendingPathComponent("upstream.command")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: isolatedStatus, withIntermediateDirectories: true)
        try AgentMetadataRuntime.proxyScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try "".write(to: upstream, atomically: true, encoding: .utf8)

        let id = UUID()
        let payload = Data("{\"model\":{\"id\":\"claude-sonnet-4-6\"}}\n".utf8)
        let output = try runProxy(
            script: script,
            agentID: id,
            upstream: upstream,
            home: home,
            statusDirectory: isolatedStatus,
            payload: payload)

        #expect(output.status == 0)
        #expect(try Data(contentsOf: isolatedStatus
            .appendingPathComponent("\(id.uuidString).metadata.json")) == payload)
        #expect(!fm.fileExists(atPath: home
            .appendingPathComponent(".config/ghostty-agents/status")
            .path))
    }

    private func runProxy(
        script: URL,
        agentID: UUID,
        upstream: URL,
        home: URL,
        statusDirectory: URL? = nil,
        payload: Data
    ) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = script
        process.arguments = [agentID.uuidString, upstream.path]
        var environment = [
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/bin/sh",
            "TMPDIR": home.path,
        ]
        if let statusDirectory {
            environment["GHOSTTY_AGENT_STATUS_DIR"] = statusDirectory.path
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: payload)
        try input.fileHandleForWriting.close()
        let stdout = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        return (process.terminationStatus, stdout)
    }
}
