import Foundation

/// The `auto` loop LiveIsland started, written down so the next launch can end it if
/// LiveIsland crashed and left it running. Only a process with this pid that started at this
/// moment, now orphaned and still running `auto`, is that loop: a loop the person started in
/// Terminal, or a reused pid, never matches.
public struct AutoLoopRecord: Codable, Equatable, Sendable {
    /// What's known about a running process, from the system.
    public struct Running: Equatable, Sendable {
        public var pid: Int32
        public var parent: Int32
        public var startedAt: TimeInterval
        public var arguments: [String]

        public init(pid: Int32, parent: Int32, startedAt: TimeInterval, arguments: [String]) {
            self.pid = pid
            self.parent = parent
            self.startedAt = startedAt
            self.arguments = arguments
        }
    }

    public var pid: Int32
    /// The process's start, in seconds since 1970, as the system reports it.
    public var startedAt: TimeInterval

    public init(pid: Int32, startedAt: TimeInterval) {
        self.pid = pid
        self.startedAt = startedAt
    }

    /// Whether `process` is this loop, left behind: launchd adopted it when LiveIsland died.
    public func isOrphan(_ process: Running?) -> Bool {
        guard let process, process.pid == pid, process.parent == 1 else { return false }
        guard abs(process.startedAt - startedAt) < 0.01 else { return false }
        return process.arguments.contains("auto") && process.arguments.contains("--json")
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> AutoLoopRecord? { try? JSONDecoder().decode(Self.self, from: data) }
}
