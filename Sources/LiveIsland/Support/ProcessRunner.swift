import Foundation

enum ProcessRunner {
    struct Result {
        let status: Int32
        let errorOutput: String
    }

    enum Failure: LocalizedError {
        /// It ran past its time and was stopped.
        case timedOut(TimeInterval)

        var errorDescription: String? {
            switch self {
            case .timedOut(let seconds): return "It didn't finish within \(Int(seconds)) s and was stopped."
            }
        }
    }

    /// Runs a command to completion without blocking the caller. With a `timeout`, a command
    /// still running then is stopped (SIGTERM, then SIGKILL) and `Failure.timedOut` thrown.
    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Drained while it runs, so a chatty tool can't fill the pipe and stall.
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let collected = OutputBuffer()
        let outcome = try await watch(process, pipes: [errorPipe], timeout: timeout) { chunk, _ in collected.append(chunk) }
        if outcome.timedOut, let timeout { throw Failure.timedOut(timeout) }
        return Result(status: outcome.status, errorOutput: collected.text)
    }

    /// Runs a command and returns what it printed. With a `timeout`, see `run`.
    static func output(_ executable: String, _ arguments: [String], timeout: TimeInterval? = nil) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let collected = OutputBuffer()
        let outcome = try await watch(process, pipes: [pipe], timeout: timeout) { chunk, _ in collected.append(chunk) }
        if outcome.timedOut, let timeout { throw Failure.timedOut(timeout) }
        return collected.contents
    }

    // MARK: - Watching a process

    struct Outcome {
        let status: Int32
        /// Stopped because it ran past its time.
        let timedOut: Bool
    }

    /// How long a stopped command gets to quit before it's killed.
    static let killGrace: TimeInterval = 2
    /// How long to wait for the pipes to close once the command has exited. Its output is
    /// complete only at EOF, so this normally ends at once; something it started in the
    /// background can hold a pipe open forever, though, and must not keep the caller waiting.
    static let eofGrace: TimeInterval = 2

    /// Launches `process` and returns once it has exited and every pipe in `pipes` has reached
    /// EOF (or `eofGrace` after the exit), handing each chunk to `receive` with its pipe's index
    /// as it arrives, from the pipes' threads. The caller sets the pipes on the process first.
    static func watch(_ process: Process, pipes: [Pipe], timeout: TimeInterval?,
                      receive: @escaping @Sendable (Data, Int) -> Void) async throws -> Outcome {
        let watcher = Watcher(pipes: pipes.count)
        return try await withCheckedThrowingContinuation { continuation in
            watcher.onFinish = { continuation.resume(returning: $0) }
            for (index, pipe) in pipes.enumerated() {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        watcher.reachedEOF()
                    } else {
                        receive(chunk, index)
                    }
                }
            }
            process.terminationHandler = { process in
                watcher.exited(process.terminationStatus)
                DispatchQueue.global().asyncAfter(deadline: .now() + eofGrace) {
                    // Something still holds a pipe: stop listening and answer with what came.
                    for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
                    watcher.giveUpOnEOF()
                }
            }
            do {
                try process.run()
            } catch {
                for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
                watcher.onFinish = nil
                continuation.resume(throwing: error)
                return
            }
            if let timeout { stop(process, after: timeout, watcher: watcher) }
        }
    }

    /// SIGTERM at `timeout`, then SIGKILL `killGrace` later if it's still there.
    private static func stop(_ process: Process, after timeout: TimeInterval, watcher: Watcher) {
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            guard process.isRunning else { return }
            watcher.markTimedOut()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }
}

/// Finishes once: when the process has exited and every pipe is at EOF, or when told to stop
/// waiting for EOF after the exit.
private final class Watcher: @unchecked Sendable {
    private let lock = NSLock()
    private var openPipes: Int
    private var status: Int32?
    private var timedOut = false
    private var finished = false
    var onFinish: ((ProcessRunner.Outcome) -> Void)?

    init(pipes: Int) { openPipes = pipes }

    func reachedEOF() { update { $0.openPipes -= 1 } }
    func exited(_ status: Int32) { update { $0.status = status } }
    func markTimedOut() { lock.lock(); timedOut = true; lock.unlock() }
    func giveUpOnEOF() { update { $0.openPipes = 0 } }

    private func update(_ change: (Watcher) -> Void) {
        lock.lock()
        change(self)
        guard !finished, openPipes <= 0, let status else { lock.unlock(); return }
        finished = true
        let outcome = ProcessRunner.Outcome(status: status, timedOut: timedOut)
        let finish = onFinish
        onFinish = nil
        lock.unlock()
        finish?(outcome)
    }
}

/// Output collected from a pipe's thread.
private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var contents: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
