import Foundation
import Testing
@testable import Ghostty

struct AgentHookScriptTests {
    @Test func hookHasValidPOSIXShellSyntax() throws {
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input

        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(AgentConfig.hookScript.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
    }

    @Test func concurrentHooksAppendOneValidRecordEach() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("clawddy-hook-tests-\(UUID().uuidString)")
        let status = root.appendingPathComponent(".config/ghostty-agents/status")
        let script = root.appendingPathComponent("clawddy-hook.sh")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: status, withIntermediateDirectories: true)
        try AgentConfig.hookScript.write(to: script, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let agentID = UUID().uuidString
        let eventCount = 24
        var processes: [Process] = []

        for index in 0..<eventCount {
            let process = Process()
            let input = Pipe()
            process.executableURL = script
            process.environment = [
                "GHOSTTY_AGENT_NAME": agentID,
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
            process.standardInput = input
            try process.run()
            let payload = Data(
                "{\"session_id\":\"session-\(index)\",\"hook_event_name\":\"UserPromptSubmit\"}\n".utf8)
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            processes.append(process)
        }

        for process in processes {
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        let journal = status.appendingPathComponent("\(agentID).events")
        let data = try Data(contentsOf: journal)
        let batch = AgentEventJournal.read(data, from: 0)
        let sessionIDs = try Set(batch.records.map { record in
            let object = try #require(JSONSerialization.jsonObject(with: record) as? [String: String])
            return try #require(object["session_id"])
        })

        #expect(batch.records.count == eventCount)
        #expect(sessionIDs.count == eventCount)
        #expect(batch.endOffset == data.count)
    }

    @Test func explicitStatusDirectoryIsIndependentFromHome() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("clawddy-hook-tests-\(UUID().uuidString)")
        let home = root.appendingPathComponent("account-home")
        let isolatedStatus = root.appendingPathComponent("isolated/status")
        let script = root.appendingPathComponent("clawddy-hook.sh")
        defer { try? fm.removeItem(at: root) }

        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: isolatedStatus, withIntermediateDirectories: true)
        try AgentConfig.hookScript.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let agentID = UUID().uuidString
        let process = Process()
        let input = Pipe()
        process.executableURL = script
        process.environment = [
            "GHOSTTY_AGENT_NAME": agentID,
            "GHOSTTY_AGENT_STATUS_DIR": isolatedStatus.path,
            "HOME": home.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(
            "{\"session_id\":\"isolated-session\",\"hook_event_name\":\"SessionStart\"}\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: isolatedStatus
            .appendingPathComponent("\(agentID).session"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "isolated-session")
        #expect(!fm.fileExists(atPath: home
            .appendingPathComponent(".config/ghostty-agents/status")
            .path))
    }
}
