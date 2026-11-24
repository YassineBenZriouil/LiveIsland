import Foundation

/// Reads Claude Code session transcripts (~/.claude/projects/<project>/<session>.jsonl).
public enum ClaudeTranscript {
    public struct UsageRecord: Equatable, Sendable {
        /// The response's id: `msg_…` from Anthropic, other shapes from proxies, or the
        /// request id when there's no message id.
        public let messageID: String
        public let timestamp: Date
        public let counts: TokenCounts
        public let model: String?
        /// The working directory's folder name, for per-project totals.
        public let project: String?

        public init(messageID: String, timestamp: Date, counts: TokenCounts, model: String?, project: String? = nil) {
            self.messageID = messageID
            self.timestamp = timestamp
            self.counts = counts
            self.model = model
            self.project = project
        }

        /// Every token, cache reads included.
        public var tokens: Int { counts.total }
    }

    static let assistantMarker = #""type":"assistant""#

    /// The token use of one assistant response. A response is written as several lines (one
    /// per content block) that share a message ID, so callers keep one record per ID.
    /// `assistantAt` is where the scanner saw `"type":"assistant"`, if it did: the fields
    /// needed sit right around it, so only those bytes are read.
    public static func usageRecord(in line: Data, assistantAt hint: Int? = nil) -> UsageRecord? {
        guard let hit = hint ?? JSONLScanner.range(of: Array(assistantMarker.utf8), in: line, last: false)?.lowerBound,
              hit < line.count
        else { return nil }
        // Claude Code writes the line's own fields after `message`: the request id, the type,
        // then the timestamp. Read from the marker on (the last timestamp is the line's).
        let after = hit..<line.count
        guard let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, within: after, last: true)
                ?? JSONLScanner.string(after: #""timestamp":""#, in: line, last: true),
              let timestamp = Format.date(iso8601: stamp)
        else { return nil }
        // API errors and limit notices come as made-up replies with no real use.
        if JSONLScanner.range(of: Array(#""isApiErrorMessage":true"#.utf8), in: line, within: after, last: false) != nil { return nil }

        // message.usage ends just before the marker; content comes earlier and may hold a
        // "usage" key of its own (a tool's input), so it's the last one before the marker.
        let usageKey = #""usage":{"#
        guard let open = JSONLScanner.lastRange(of: usageKey, in: line, before: hit)
                ?? JSONLScanner.range(of: Array(usageKey.utf8), in: line, last: true),
              let usage = JSONLScanner.object(openingAt: open.upperBound - 1, in: line)
        else { return nil }
        func count(_ key: String, in object: [String: Any]) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        let counts = TokenCounts(
            input: count("input_tokens", in: usage), output: count("output_tokens", in: usage),
            cacheWrite: count("cache_creation_input_tokens", in: usage),
            cacheWrite1h: (usage["cache_creation"] as? [String: Any]).map { count("ephemeral_1h_input_tokens", in: $0) } ?? 0,
            cacheRead: count("cache_read_input_tokens", in: usage))

        let message = JSONLScanner.range(of: Array(#""message":{"#.utf8), in: line, last: false)
        let beforeUsage = message.flatMap { $0.lowerBound < open.lowerBound ? $0.lowerBound..<open.lowerBound : nil }
        let model = JSONLScanner.string(after: #""model":""#, in: line, within: beforeUsage)
        guard model != "<synthetic>", let id = messageID(in: line, message: message) else { return nil }
        let cwd = message.flatMap { JSONLScanner.string(after: #""cwd":""#, in: line, within: 0..<$0.lowerBound) }
        let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        return UsageRecord(messageID: id, timestamp: timestamp, counts: counts, model: model, project: project)
    }

    /// The response's message ID: the first id in `message` that isn't a tool call's. Proxies
    /// and other gateways use their own shapes ("chatcmpl-…", a UUID), so any value counts;
    /// with no id at all, the request id still ties a response's lines together.
    public static func messageID(in line: Data) -> String? {
        messageID(in: line, message: JSONLScanner.range(of: Array(#""message":{"#.utf8), in: line, last: false))
    }

    private static func messageID(in line: Data, message: Range<Int>?) -> String? {
        if let message {
            var from = message.upperBound
            while from < line.count,
                  let key = JSONLScanner.range(of: Array(#""id":""#.utf8), in: line, within: from..<line.count, last: false),
                  let value = JSONLScanner.string(after: #""id":""#, in: line, within: key.lowerBound..<line.count) {
                if !value.isEmpty, !value.hasPrefix("toolu_"), !value.hasPrefix("srvtoolu_") { return value }
                from = key.upperBound
            }
        }
        return JSONLScanner.string(after: #""requestId":""#, in: line, last: true).flatMap { $0.isEmpty ? nil : "req:" + $0 }
    }

    /// A usage-limit notice, logged when Claude Code hits (or nears) a limit. A notice with
    /// no timestamp of its own takes `undatedObservedAt` (when the line before it was written,
    /// say); without one it's dropped: an unknown time can't be compared with later replies,
    /// and guessing one in the future would keep the notice up for good.
    public static func limitNotice(in line: Data, undatedObservedAt fallback: Date? = nil) -> ClaudeLimitNotice? {
        guard JSONLScanner.contains(line, #""rate_limit_info""#),
              let info = JSONLScanner.object(forKey: "rate_limit_info", in: line),
              let status = info["status"] as? String,
              let resets = (info["resetsAt"] as? NSNumber)?.doubleValue,
              let observedAt = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true).flatMap(Format.date(iso8601:)) ?? fallback
        else { return nil }
        return ClaudeLimitNotice(
            status: status, type: info["rateLimitType"] as? String ?? "limit",
            resetsAt: Date(timeIntervalSince1970: resets), observedAt: observedAt)
    }

    /// What the end of a transcript says about the session.
    public struct Tail: Equatable, Sendable {
        public enum Step: Equatable, Sendable {
            /// The model finished its turn.
            case finished
            /// The model asked to run a tool.
            case calledTool
            /// A prompt, tool result or API request is waiting on the model.
            case awaitingModel
        }

        public var lastStep: Step?
        public var lastTimestamp: Date?
        /// When the latest prompt was sent, for "working 3m".
        public var turnStartedAt: Date?
        public var title: String?
        public var cwd: String?

        public init() {}
    }

    /// Reads the meaningful steps from the last lines of a transcript.
    public static func tail(of lines: [Data]) -> Tail {
        var tail = Tail()
        for line in lines {
            if let title = JSONLScanner.string(after: #""aiTitle":""#, in: line) { tail.title = title }
            if tail.cwd == nil, let cwd = JSONLScanner.string(after: #""cwd":""#, in: line) { tail.cwd = cwd }
            let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true).flatMap(Format.date(iso8601:))

            let step: Tail.Step?
            if JSONLScanner.contains(line, #""type":"assistant""#) {
                let reason = JSONLScanner.string(after: #""stop_reason":""#, in: line, last: true)
                step = reason == "end_turn" ? .finished : reason == "tool_use" ? .calledTool : .awaitingModel
            } else if JSONLScanner.contains(line, #""type":"user""#) {
                step = .awaitingModel
                // A typed prompt (not a tool result) starts a new turn.
                if !JSONLScanner.contains(line, #""tool_result""#) { tail.turnStartedAt = stamp ?? tail.turnStartedAt }
            } else if JSONLScanner.contains(line, #""type":"api-request""#) {
                step = .awaitingModel
            } else {
                step = nil
            }
            if let step {
                tail.lastStep = step
                if let stamp { tail.lastTimestamp = stamp }
            }
        }
        return tail
    }

    /// The session's state, from its tail and how long the file has been quiet.
    public static func state(of tail: Tail, modified: Date, now: Date) -> AgentState {
        let quiet = now.timeIntervalSince(modified)
        switch tail.lastStep {
        case .finished:
            return quiet < 20 ? .done : .idle
        case .calledTool:
            // Fresh writes mean the tool just ran; a long pause means a slow tool or an approval prompt.
            if quiet < 8 { return .working }
            return quiet < 30 * 60 ? .waiting : .idle
        case .awaitingModel:
            // Thinking can go a while without writing anything.
            return quiet < 10 * 60 ? .working : .idle
        case nil:
            return .idle
        }
    }

    /// The project's folder name, from the session's working directory.
    /// The folder name Claude Code files a project's transcripts under: the path with every
    /// character other than a letter or digit turned into "-".
    public static func projectKey(for folder: String) -> String {
        String(folder.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    public static func projectName(cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
