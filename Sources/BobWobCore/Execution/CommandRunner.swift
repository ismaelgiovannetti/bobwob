import Foundation

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
}

public enum CommandRunner {
    /// Runs without a shell. The tool's folder joins PATH because npm and conda need their
    /// own interpreter, which an app launched from the Finder would not find.
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 600) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = [
                    executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
                ].joined(separator: ":")
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timer = DispatchWorkItem { process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: CommandResult(
                    status: process.terminationStatus,
                    output: String(decoding: output, as: UTF8.self)
                ))
            }
        }
    }
}
