import Foundation

/// Runs the Run AppleScript step's script with `/usr/bin/osascript`. A child process (rather than
/// in-process `NSAppleScript`) keeps a slow or stuck script off the main thread and lets it be killed
/// when it overruns its time limit.
nonisolated enum AppleScriptRunner {
    static let defaultTimeoutSeconds = 60
    static let timeoutRange = 1...600

    struct Failure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    private static func lines(of script: String) -> [String] {
        script.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The first non-empty line, for the one-line summary under the step.
    static func firstLine(of script: String) -> String? { lines(of: script).first }

    static func hasSeveralLines(_ script: String) -> Bool { lines(of: script).count > 1 }

    /// Returns what the script printed (its result), or throws with the script's own error message.
    static func run(_ script: String, timeoutSeconds: Int) async throws -> String {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure(message: "the script is empty") }
        let limit = min(max(timeoutSeconds, timeoutRange.lowerBound), timeoutRange.upperBound)
        return try await Task.detached(priority: .utility) { try runBlocking(trimmed, limit: limit) }.value
    }

    private static func runBlocking(_ script: String, limit: Int) throws -> String {
        do {
            let process = Process()
            let input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // "-" reads the script from stdin, so nothing needs escaping on a command line.
            process.arguments = ["-"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors

            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do { try process.run() } catch {
                throw Failure(message: "couldn't start osascript: \(error.localizedDescription)")
            }

            // Drain both pipes while the script runs so a chatty script can't fill a pipe and hang.
            let outData = LockedData(), errData = LockedData()
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { outData.append(chunk) }
            }
            errors.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil } else { errData.append(chunk) }
            }

            try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
            try? input.fileHandleForWriting.close()

            if finished.wait(timeout: .now() + .seconds(limit)) == .timedOut {
                process.terminate()
                if finished.wait(timeout: .now() + .seconds(2)) == .timedOut { kill(process.processIdentifier, SIGKILL) }
                throw Failure(message: "it didn't finish within \(limit) second\(limit == 1 ? "" : "s") and was stopped")
            }

            // Let the handlers pick up whatever was still buffered at exit.
            Thread.sleep(forTimeInterval: 0.05)
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            outData.append((try? output.fileHandleForReading.readToEnd()) ?? Data())
            errData.append((try? errors.fileHandleForReading.readToEnd()) ?? Data())

            let result = String(decoding: outData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                let message = String(decoding: errData.value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure(message: message.isEmpty ? "osascript exited with status \(process.terminationStatus)" : message)
            }
            return result
        }
    }
}

private nonisolated final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
