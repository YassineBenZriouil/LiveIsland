import Foundation

/// Quoting for the few scripts LiveIsland writes for Terminal, so a name the person typed is
/// only ever text there.
public enum Shell {
    /// `text` as one single-quoted word: nothing in it expands, not `$(…)`, not `"`.
    public static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A command that prints `text` as it is, on a line of its own.
    public static func echo(_ text: String) -> String {
        "printf '%s\\n' " + quoted(text)
    }
}

/// How long to wait before starting an `auto` loop again after it stopped or didn't start.
/// A loop that crashes right after its first check would otherwise restart every few seconds
/// forever, asking about every account each time; one that ran a good while had a real run,
/// so its next stop starts over from the shortest wait.
public struct RestartBackoff: Equatable, Sendable {
    public static let delays: [TimeInterval] = [5, 15, 60, 300]
    /// A run at least this long counts as healthy.
    public static let healthyRun: TimeInterval = 600

    public private(set) var failures = 0

    public init() {}

    /// The wait after a stop. `ran` is how long the loop ran, nil when it never started.
    public mutating func delay(afterRunning ran: TimeInterval?) -> TimeInterval {
        if let ran, ran >= Self.healthyRun { failures = 0 }
        failures += 1
        return Self.delays[min(failures, Self.delays.count) - 1]
    }

    /// The person turned it off or on again: their new start is a fresh one.
    public mutating func reset() { failures = 0 }
}

/// What a running process was started with, from the kernel's `KERN_PROCARGS2` answer: the
/// argument count, the executable's path, its arguments, then its environment, each
/// NUL-terminated (with NUL padding after the path).
public struct ProcessArguments: Equatable, Sendable {
    public let arguments: [String]
    public let environment: [String]

    public init(arguments: [String], environment: [String]) {
        self.arguments = arguments
        self.environment = environment
    }

    public static func parse(_ data: Data) -> ProcessArguments? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        // A native (little-endian on every Mac) 32-bit count.
        let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let count = Int(Int32(bitPattern: raw))
        guard count >= 0 else { return nil }
        var index = 4
        func next() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return text
        }
        guard next() != nil else { return nil }  // the executable's path
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let argument = next() else { return nil }
            arguments.append(argument)
        }
        // The environment ends at an empty string; Apple's own strings follow it.
        var environment: [String] = []
        while let variable = next(), !variable.isEmpty { environment.append(variable) }
        return ProcessArguments(arguments: arguments, environment: environment)
    }

    public func value(of key: String) -> String? {
        environment.lazy.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
}

/// How LiveIsland knows an `auto` loop is its own, so after a crash it ends only its own
/// loops, never one the person runs in Terminal. Two marks, since either can be missing: a
/// variable in the loop's environment (macOS hides the environment of Apple's own programs,
/// such as /usr/bin/python3), and the process ID LiveIsland wrote down when it started it.
public enum AutoLoopMark {
    public static let key = "LIVEISLAND_AUTO_LOOP"

    /// Whether a process found running was started by LiveIsland as `tool`'s loop.
    public static func isLiveIslands(_ process: ProcessArguments, tool: String) -> Bool {
        process.value(of: key) == tool
    }

    /// The same, from both marks: `started` is what the kernel says the process was started
    /// with (nil when it won't say), `recorded` the IDs LiveIsland wrote down.
    public static func isLiveIslands(pid: Int32, started: ProcessArguments?, recorded: Set<Int32>, tool: String) -> Bool {
        recorded.contains(pid) || started.map { isLiveIslands($0, tool: tool) } == true
    }

    /// The process IDs in a file LiveIsland wrote, one per line.
    public static func pids(in text: String) -> Set<Int32> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 1 })
    }
}
