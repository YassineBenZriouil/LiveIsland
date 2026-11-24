import Foundation

/// When an agent starts needing the person, and what to tell them, for the notification sent
/// while the island can't be seen (over a full-screen app, the screen locked).
///
/// Only the change counts: a session that already needed the person when LiveIsland last
/// looked was announced then, or was there before LiveIsland started, so it isn't announced
/// again on every snapshot.
public struct AgentAlerts: Equatable, Sendable {
    /// Whether each session needed the person at the last look; nil before the first one.
    private var needing: [String: Bool]?

    public init() {}

    /// Whether the session is stopped on the person: a tool waiting for permission, or a turn
    /// that ended on a question. An idle session's old question is history, not a call.
    public static func needsPerson(_ session: AgentSession) -> Bool {
        switch session.state {
        case .waiting: return true
        case .done: return session.request?.kind == .question
        case .working, .idle: return false
        }
    }

    /// What changed since the last look: sessions that now need the person (to announce) and
    /// the ids of those that no longer do (whose notification can go). The first look only
    /// remembers, so what was already waiting at launch isn't announced.
    public mutating func update(_ sessions: [AgentSession]) -> (started: [AgentSession], ended: [String]) {
        let now = Dictionary(sessions.map { ($0.id, Self.needsPerson($0)) }, uniquingKeysWith: { first, _ in first })
        defer { needing = now }
        guard let before = needing else { return ([], []) }
        let started = sessions.filter { now[$0.id] == true && before[$0.id] != true }
        let ended = before.filter { $0.value && now[$0.key] != true }.map(\.key).sorted()
        return (started, ended)
    }

    /// The notification's title and body. With details hidden (the screen is shared), only the
    /// agent and the kind of request show: no project, no command, no question.
    public static func message(for session: AgentSession, hidingDetails: Bool) -> (title: String, body: String) {
        let title = "\(session.kind.displayName) needs you"
        let generic = session.request?.kind == .question ? "Has a question" : "Needs permission"
        guard !hidingDetails else { return (title, generic) }
        let detail = session.request?.text ?? generic
        return (title, session.project.isEmpty ? detail : "\(session.project): \(detail)")
    }
}

public extension AgentRequest {
    /// The longest label the closed island's wing holds.
    static let compactLength = 9

    /// A word or two for the closed island's narrow wing: the tool waiting ("Bash?"), or
    /// "Question". An MCP tool goes by its own name, without the server's prefix.
    var compactLabel: String {
        guard kind == .permission, let tool, !tool.isEmpty else { return kind == .question ? "Question" : "Needs you" }
        // "mcp__server__tool_name" → "tool_name".
        let name = tool.components(separatedBy: "__").last.flatMap { $0.isEmpty ? nil : $0 } ?? tool
        let short = name.count > Self.compactLength - 1 ? String(name.prefix(Self.compactLength - 2)) + "…" : name
        return short + "?"
    }

    /// The symbol beside the request: a raised hand for permission, a bubble for a question.
    var symbol: String { kind == .question ? "questionmark.bubble.fill" : "hand.raised.fill" }
}
