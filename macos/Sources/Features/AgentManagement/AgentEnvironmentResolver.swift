import Foundation
import os

private let environmentLogger = Logger(
    subsystem: "com.mitchellh.ghostty",
    category: "AgentEnvironment")

enum AgentEnvironmentResolver {
    private static let marker = "__CLAWDDY_PATH__"
    private static let queue = DispatchQueue(
        label: "clawddy.environment",
        qos: .userInitiated)

    static var fallbackPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let preferred = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        return orderedUnique(preferred + inherited).joined(separator: ":")
    }

    static func resolve(timeout: TimeInterval = 3, completion: @escaping (String) -> Void) {
        let fallback = fallbackPath
        queue.async {
            let shell = validatedShell()
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            let completionSignal = DispatchSemaphore(value: 0)
            let dataLock = NSLock()
            var outputData = Data()

            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s\\n' \"$PATH\""]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = errors

            output.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                dataLock.withLock { outputData.append(data) }
            }
            // Drain stderr concurrently so verbose shell startup cannot block.
            errors.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }
            process.terminationHandler = { _ in completionSignal.signal() }

            do {
                try process.run()
            } catch {
                finish(fallback, completion: completion)
                environmentLogger.error("shell PATH resolution failed: \(error.localizedDescription)")
                return
            }

            if completionSignal.wait(timeout: .now() + timeout) == .timedOut {
                environmentLogger.warning("shell PATH resolution timed out; using fallback")
                process.terminate()
                _ = completionSignal.wait(timeout: .now() + 1)
            }

            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            let captured = dataLock.withLock { outputData }
            let path = parsePath(from: captured) ?? fallback
            finish(path, completion: completion)
        }
    }

    static func parsePath(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0.isNewline }).reversed() {
            guard line.hasPrefix(marker) else { continue }
            let path = line.dropFirst(marker.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            return orderedUnique(path.split(separator: ":").map(String.init))
                .joined(separator: ":")
        }
        return nil
    }

    private static func validatedShell() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard shell.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: shell)
        else { return "/bin/zsh" }
        return shell
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func finish(_ path: String, completion: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            completion(path)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
