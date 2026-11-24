import Foundation

/// Reads Claude Code session transcripts (~/.claude/projects/<project>/<session>.jsonl).
public enum ClaudeTranscript {
    public struct UsageRecord: Equatable, Sendable {
        public let messageID: String
        public let timestamp: Date
        public let tokens: Int
        public let model: String?
    }

    /// The token use of one assistant response. A response is written as several lines (one
    /// per content block) that share a message ID, so callers count each ID once.
    public static func usageRecord(in line: Data) -> UsageRecord? {
        guard JSONLScanner.contains(line, #""type":"assistant""#),
              // message.usage follows the content, which may itself contain a "usage" key: take the last.
              let usage = JSONLScanner.object(forKey: "usage", in: line, last: true),
              let idSuffix = JSONLScanner.string(after: #""id":"msg_"#, in: line),
              let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true),
              let timestamp = Format.date(iso8601: stamp)
        else { return nil }
        let keys = ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
        let tokens = keys.reduce(0) { $0 + ((usage[$1] as? NSNumber)?.intValue ?? 0) }
        return UsageRecord(messageID: "msg_" + idSuffix, timestamp: timestamp, tokens: tokens,
                           model: JSONLScanner.string(after: #""model":""#, in: line))
    }

    /// The response's message ID, cheap to read, so repeated lines can be skipped early.
    public static func messageID(in line: Data) -> String? {
        JSONLScanner.string(after: #""id":"msg_"#, in: line).map { "msg_" + $0 }
    }

    /// A usage-limit notice, logged when Claude Code hits (or nears) a limit.
    public static func limitNotice(in line: Data) -> ClaudeLimitNotice? {
        guard JSONLScanner.contains(line, #""rate_limit_info""#),
              let info = JSONLScanner.object(forKey: "rate_limit_info", in: line),
              let status = info["status"] as? String,
              let resets = (info["resetsAt"] as? NSNumber)?.doubleValue
        else { return nil }
        let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line, last: true).flatMap(Format.date(iso8601:))
        return ClaudeLimitNotice(
            status: status, type: info["rateLimitType"] as? String ?? "limit",
            resetsAt: Date(timeIntervalSince1970: resets), observedAt: stamp ?? Date(timeIntervalSince1970: resets))
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
            /// The person pressed Esc: the turn ended without finishing.
            case interrupted
        }

        public var lastStep: Step?
        /// When the last step was written (the line's own time, not one inside a tool's result).
        public var lastTimestamp: Date?
        /// When the latest prompt was sent, for "working 3m".
        public var turnStartedAt: Date?
        public var title: String?
        public var cwd: String?
        /// The tool waiting to run, or the question the model ended its turn on. `request(of:state:)`
        /// says when it applies.
        public var pendingRequest: AgentRequest?

        public init() {}
    }

    /// Reads the meaningful steps from the last lines of a transcript.
    public static func tail(of lines: [Data]) -> Tail {
        var tail = Tail()
        // A slash command's time: a turn it starts (/init) begins there, not at its API request.
        var commandAt: Date?
        // The last lines that may hold a pending request, decoded only once, after the loop.
        var toolUseLine: Data?
        var textLine: Data?
        for line in lines {
            if let title = JSONLScanner.string(after: #""aiTitle":""#, in: line) { tail.title = title }
            let fields = TopLevel(line)
            // Subagent lines and tool progress carry their own messages: the parent's turn goes on.
            if fields.isSidechain || fields.type == "progress" { continue }
            if tail.cwd == nil, let cwd = JSONLScanner.string(after: #""cwd":""#, in: line) { tail.cwd = cwd }
            let stamp = fields.timestamp.flatMap(Format.date(iso8601:))

            let step: Tail.Step?
            switch fields.type {
            case "assistant":
                let reason = JSONLScanner.string(after: #""stop_reason":""#, in: line, last: true)
                step = reason == "end_turn" ? .finished : reason == "tool_use" ? .calledTool : .awaitingModel
                if JSONLScanner.contains(line, #""type":"tool_use""#) {
                    toolUseLine = line
                    textLine = nil
                } else if JSONLScanner.contains(line, #""type":"text""#) {
                    textLine = line
                }
            case "user":
                step = userStep(line, fields: fields)
                switch step {
                case .awaitingModel? where JSONLScanner.contains(line, #""tool_result""#):
                    break
                case .awaitingModel?:
                    // A typed prompt (not a tool result) starts a new turn.
                    tail.turnStartedAt = stamp ?? tail.turnStartedAt
                case nil where isCommand(line):
                    commandAt = stamp
                default:
                    break
                }
                if step != nil {
                    toolUseLine = nil
                    textLine = nil
                }
            case "api-request":
                step = .awaitingModel
                // A request after the turn ended means a slash command started a new one.
                if tail.lastStep == .finished || tail.lastStep == .interrupted || tail.lastStep == nil && commandAt != nil {
                    tail.turnStartedAt = commandAt ?? stamp ?? tail.turnStartedAt
                }
                commandAt = nil
            default:
                step = nil
            }
            if let step {
                tail.lastStep = step
                if let stamp { tail.lastTimestamp = stamp }
            }
        }
        switch tail.lastStep {
        case .calledTool: tail.pendingRequest = toolUseLine.flatMap(toolRequest(in:))
        case .finished: tail.pendingRequest = textLine.flatMap(question(in:))
        default: break
        }
        return tail
    }

    /// What a user line means for the turn: nil for lines the model never sees as a prompt
    /// (a local slash command and its output, meta lines, a compaction summary).
    static func userStep(_ line: Data, fields: TopLevel) -> Tail.Step? {
        // Checked first: an interrupted tool's result can say so too.
        if JSONLScanner.contains(line, #""text":"[Request interrupted by user"#)
            || JSONLScanner.contains(line, #""content":"[Request interrupted by user"#) {
            return .interrupted
        }
        if fields.isMeta || JSONLScanner.contains(line, #""isCompactSummary":true"#) { return nil }
        if isCommand(line) { return nil }
        return .awaitingModel
    }

    /// A slash command, or what a local one printed (`/model`, `/cost`).
    static func isCommand(_ line: Data) -> Bool {
        ["<command-name>", "<command-message>", "<local-command-stdout>", "<local-command-stderr>", "<local-command-caveat>"]
            .contains { JSONLScanner.contains(line, #""content":"\#($0)"#) || JSONLScanner.contains(line, #""text":"\#($0)"#) }
    }

    /// What the session needs from the person, if anything, given its state: a tool waiting
    /// for permission only while it waits, a question only once the turn is over.
    public static func request(of tail: Tail, state: AgentState) -> AgentRequest? {
        guard let request = tail.pendingRequest else { return nil }
        switch (request.kind, state) {
        case (_, .waiting): return request
        case (.question, .done), (.question, .idle): return tail.lastStep == .finished ? request : nil
        default: return nil
        }
    }

    /// The last tool the model asked to run, with a short line about what it does.
    static func toolRequest(in line: Data) -> AgentRequest? {
        guard let use = blocks(in: line).last(where: { $0["type"] as? String == "tool_use" }),
              let name = use["name"] as? String
        else { return nil }
        let input = use["input"] as? [String: Any] ?? [:]
        if name == "AskUserQuestion",
           let first = (input["questions"] as? [[String: Any]])?.first, let question = first["question"] as? String {
            return AgentRequest(kind: .question, tool: name, summary: question)
        }
        return AgentRequest(kind: .permission, tool: name, summary: summary(ofTool: name, input: input))
    }

    /// The question a turn ended on: the last line of its text, when that asks something.
    static func question(in line: Data) -> AgentRequest? {
        guard let text = blocks(in: line).last(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let last = text.split(whereSeparator: \.isNewline).last?.trimmingCharacters(in: .whitespaces),
              last.hasSuffix("?")
        else { return nil }
        return AgentRequest(kind: .question, summary: last)
    }

    /// A tool's input in a few words: the command, the file, the address.
    static func summary(ofTool name: String, input: [String: Any]) -> String? {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash": return string("description") ?? string("command")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return (string("file_path") ?? string("notebook_path")).map { URL(fileURLWithPath: $0).lastPathComponent }
        case "WebFetch": return string("url").flatMap { URL(string: $0)?.host ?? $0 }
        case "ExitPlanMode": return "Plan ready to review"
        default:
            return ["description", "command", "file_path", "path", "url", "query", "pattern", "prompt"].lazy
                .compactMap(string).first
        }
    }

    /// The content blocks of an assistant line's message.
    private static func blocks(in line: Data) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = object["message"] as? [String: Any]
        else { return [] }
        return message["content"] as? [[String: Any]] ?? []
    }

    /// The line's own fields, found without decoding it: a tool's result nests whole messages
    /// (and their timestamps and types), so a plain search can find the wrong ones.
    struct TopLevel {
        var type: String?
        var timestamp: String?
        var isSidechain = false
        var isMeta = false

        init(_ line: Data) {
            line.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var depth = 0
                var inString = false
                var escaped = false
                var expectKey = false
                var index = 0
                let count = buffer.count

                // The end of the string whose opening quote is at `start`.
                func stringEnd(from start: Int) -> Int {
                    var cursor = start + 1
                    var escape = false
                    while cursor < count {
                        let byte = buffer[cursor]
                        if escape { escape = false } else if byte == 0x5C { escape = true } else if byte == 0x22 { return cursor }
                        cursor += 1
                    }
                    return count
                }
                func text(_ from: Int, _ to: Int) -> String {
                    String(decoding: UnsafeRawBufferPointer(rebasing: buffer[from..<to]), as: UTF8.self)
                }

                while index < count {
                    let byte = buffer[index]
                    if inString {
                        if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                        index += 1
                        continue
                    }
                    switch byte {
                    case 0x7B, 0x5B:  // { [
                        depth += 1
                        expectKey = depth == 1 && byte == 0x7B
                    case 0x7D, 0x5D:  // } ]
                        depth -= 1
                    case 0x2C:  // ,
                        if depth == 1 { expectKey = true }
                    case 0x22 where depth == 1 && expectKey:
                        expectKey = false
                        let keyEnd = stringEnd(from: index)
                        let key = text(index + 1, keyEnd)
                        var cursor = keyEnd + 1
                        while cursor < count, buffer[cursor] == 0x3A || buffer[cursor] == 0x20 { cursor += 1 }
                        guard cursor < count else { return }
                        if buffer[cursor] == 0x22 {
                            let valueEnd = stringEnd(from: cursor)
                            if key == "type" { type = text(cursor + 1, valueEnd) }
                            if key == "timestamp" { timestamp = text(cursor + 1, valueEnd) }
                            index = valueEnd + 1
                        } else {
                            if buffer[cursor] == 0x74 {  // t(rue)
                                if key == "isSidechain" { isSidechain = true }
                                if key == "isMeta" { isMeta = true }
                            }
                            index = cursor
                        }
                        continue
                    case 0x22:
                        inString = true
                    default:
                        break
                    }
                    index += 1
                }
            }
        }
    }

    /// The session's state, from its tail and how long the file has been quiet.
    public static func state(of tail: Tail, modified: Date, now: Date) -> AgentState {
        let quiet = now.timeIntervalSince(modified)
        switch tail.lastStep {
        case .finished:
            // Counted from the end of the turn too: a later `/model` writes to the file without
            // finishing anything again.
            let sinceEnd = tail.lastTimestamp.map { now.timeIntervalSince($0) } ?? quiet
            return max(quiet, sinceEnd) < 20 ? .done : .idle
        case .interrupted:
            return .idle
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

    /// The folder name Claude Code files a project's transcripts under: the path with every
    /// character other than an ASCII letter or digit turned into "-".
    public static func projectKey(for folder: String) -> String {
        String(folder.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : "-"
        })
    }

    /// The project's folder name, from the session's working directory.
    public static func projectName(cwd: String?, fallback: String) -> String {
        guard let cwd, !cwd.isEmpty else { return fallback }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
}
