import Foundation

/// Runs a child process and collects its output without blocking the main thread.
enum ProcessRunner {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
        var timedOut: Bool

        var combined: String {
            var text = stdout
            if !stderr.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + stderr }
            return text
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var flag = false

        func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        var value: Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        input: String? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 120
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var env = ProcessInfo.processInfo.environment
                for (key, value) in environment { env[key] = value }
                process.environment = env
                if let currentDirectory { process.currentDirectoryURL = currentDirectory }

                let outPipe = Pipe()
                let errPipe = Pipe()
                let inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                let out = Box()
                let err = Box()
                let timedOut = Box()
                outPipe.fileHandleForReading.readabilityHandler = { handle in out.append(handle.availableData) }
                errPipe.fileHandleForReading.readabilityHandler = { handle in err.append(handle.availableData) }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                if let input {
                    inPipe.fileHandleForWriting.write(Data(input.utf8))
                }
                try? inPipe.fileHandleForWriting.close()

                let killer = DispatchWorkItem {
                    if process.isRunning {
                        timedOut.flag = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()

                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())

                continuation.resume(returning: Result(
                    status: process.terminationStatus,
                    stdout: String(decoding: out.value, as: UTF8.self),
                    stderr: String(decoding: err.value, as: UTF8.self),
                    timedOut: timedOut.flag
                ))
            }
        }
    }

    /// Runs a command through the user's login shell so PATH (Homebrew, npm, …) is set up.
    static func shell(_ command: String, input: String? = nil, currentDirectory: URL? = nil, timeout: TimeInterval = 120,
                      environment: [String: String] = [:], arguments: [String] = []) async throws -> Result {
        try await run("/bin/zsh", arguments: ["-l", "-c", command, "jarvis"] + arguments, environment: environment,
                      input: input, currentDirectory: currentDirectory, timeout: timeout)
    }
}
