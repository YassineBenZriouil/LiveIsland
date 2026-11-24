import Foundation

/// How long to wait before starting a stopped `auto` loop again. A loop that keeps failing
/// waits longer each time; only one that ran a good while counts as healthy again, so a loop
/// that crashes right after its first poll can't restart every few seconds forever (and ask
/// for every account's usage each time).
public struct AutoRestartBackoff: Equatable, Sendable {
    public static let delays: [TimeInterval] = [5, 15, 60, 300]
    /// A loop that ran this long before stopping starts over at the shortest wait.
    public static let settledAfter: TimeInterval = 600

    public private(set) var failures = 0

    public init() {}

    /// The wait before the next start, after a loop stopped (or never started: 0 s).
    public mutating func delay(afterRunning ran: TimeInterval) -> TimeInterval {
        if ran >= Self.settledAfter { failures = 0 }
        failures += 1
        return Self.delays[min(failures - 1, Self.delays.count - 1)]
    }

    /// The person turned it off or on: whatever failed before is behind them.
    public mutating func reset() { failures = 0 }
}

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
