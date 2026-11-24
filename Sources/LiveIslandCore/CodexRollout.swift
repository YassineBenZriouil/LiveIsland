import Foundation

/// Reads Codex CLI session logs (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl).
public enum CodexRollout {
    /// The rate limits Codex reported with its latest token count.
    public static func limits(in line: Data) -> CodexLimits? {
        guard JSONLScanner.contains(line, #""rate_limits""#),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }
        let payload = object["payload"] as? [String: Any] ?? object
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        let observedAt = (object["timestamp"] as? String).flatMap(Format.date(iso8601:)) ?? Date()
        let primary = window(limits["primary"], observedAt: observedAt)
        let secondary = window(limits["secondary"], observedAt: observedAt)
        guard primary != nil || secondary != nil else { return nil }
        return CodexLimits(primary: primary, secondary: secondary, observedAt: observedAt)
    }

    /// The session's running token total.
    public static func totalTokens(in line: Data) -> Int? {
        guard JSONLScanner.contains(line, #""total_token_usage""#),
              let usage = JSONLScanner.object(forKey: "total_token_usage", in: line)
        else { return nil }
        return (usage["total_tokens"] as? NSNumber)?.intValue
    }

    public struct Tail: Equatable, Sendable {
        public var working = false
        public var awaitingApproval = false
        public var lastEventAt: Date?
        public var turnStartedAt: Date?
        public var finishedAt: Date?
        public var cwd: String?
        public var tokens: Int?
        /// The command or patch waiting for approval, while one waits.
        public var pendingRequest: AgentRequest?

        public init() {}
    }

    /// Lines that show a tool ran (or was turned down), so its approval was answered.
    static let approvalAnswers = [
        #""function_call_output""#, #""custom_tool_call_output""#, #""type":"exec_command_end""#, #""type":"patch_apply_end""#,
    ]

    public static func tail(of lines: [Data]) -> Tail {
        var tail = Tail()
        var approvalLine: Data?
        for line in lines {
            let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line).flatMap(Format.date(iso8601:))
            if tail.cwd == nil, let cwd = JSONLScanner.string(after: #""cwd":""#, in: line) { tail.cwd = cwd }
            if let tokens = totalTokens(in: line) { tail.tokens = tokens }
            if JSONLScanner.contains(line, #""type":"task_started""#) {
                tail.working = true
                tail.awaitingApproval = false
                tail.turnStartedAt = stamp
            } else if JSONLScanner.contains(line, #""type":"task_complete""#) {
                tail.working = false
                tail.awaitingApproval = false
                tail.finishedAt = stamp
            } else if JSONLScanner.contains(line, #""type":"turn_aborted""#) {
                // Stopped by the person: over, but nothing was finished to celebrate.
                tail.working = false
                tail.awaitingApproval = false
                tail.finishedAt = nil
            } else if JSONLScanner.contains(line, #"approval_request""#) {
                tail.awaitingApproval = true
                approvalLine = line
            } else if tail.awaitingApproval, approvalAnswers.contains(where: { JSONLScanner.contains(line, $0) }) {
                tail.awaitingApproval = false
            }
            if let stamp { tail.lastEventAt = stamp }
        }
        if tail.awaitingApproval { tail.pendingRequest = approvalLine.flatMap(approvalRequest(in:)) }
        return tail
    }

    public static func state(of tail: Tail, modified: Date, now: Date) -> AgentState {
        let quiet = now.timeIntervalSince(modified)
        if tail.working {
            // An approval nobody answers for half an hour is a session left behind, like any other.
            if tail.awaitingApproval { return quiet < 30 * 60 ? .waiting : .idle }
            return quiet < 30 * 60 ? .working : .idle
        }
        if let finished = tail.finishedAt, now.timeIntervalSince(finished) < 20 { return .done }
        return .idle
    }

    /// The approval the session waits on, only while it waits.
    public static func request(of tail: Tail, state: AgentState) -> AgentRequest? {
        state == .waiting ? tail.pendingRequest : nil
    }

    /// The command or the files an approval request is about.
    static func approvalRequest(in line: Data) -> AgentRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        let payload = object["payload"] as? [String: Any] ?? object
        let reason = payload["reason"] as? String
        if let changes = payload["changes"] as? [String: Any] {
            let files = changes.keys.sorted().map { URL(fileURLWithPath: $0).lastPathComponent }
            return AgentRequest(kind: .permission, tool: "Edit", summary: files.isEmpty ? reason : files.joined(separator: ", "))
        }
        var command: String?
        if let parts = payload["command"] as? [String] {
            // `bash -lc "<script>"`: the script is what matters.
            command = parts.count == 3 && parts[1].hasPrefix("-") && parts[1].hasSuffix("c") ? parts[2] : parts.joined(separator: " ")
        } else if let text = payload["command"] as? String {
            command = text
        }
        return AgentRequest(kind: .permission, tool: "Command", summary: command ?? reason)
    }

    private static func window(_ value: Any?, observedAt: Date) -> RateLimitWindow? {
        guard let window = value as? [String: Any], let used = (window["used_percent"] as? NSNumber)?.doubleValue else {
            return nil
        }
        let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
        var resetsAt: Date?
        if let epoch = (window["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: epoch)
        } else if let seconds = (window["resets_in_seconds"] as? NSNumber)?.doubleValue {
            // Older Codex versions report a countdown from when the line was written.
            resetsAt = observedAt.addingTimeInterval(seconds)
        }
        return RateLimitWindow(usedPercent: used, windowMinutes: minutes, resetsAt: resetsAt)
    }
}
