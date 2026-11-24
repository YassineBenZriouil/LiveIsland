import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}

public enum AgentState: String, Equatable, Sendable {
    /// Writing or thinking right now.
    case working
    /// Stopped in the middle of a turn: running a long tool, or waiting for approval.
    case waiting
    /// Just finished its turn.
    case done
    case idle
}

/// Where a running agent lives: the app around it (VS Code, Cursor, Terminal…), the terminal
/// it's attached to, and the folder it started in.
public struct SessionHost: Equatable, Sendable {
    public var bundleIdentifier: String
    public var processID: Int32
    /// "/dev/ttys005"; nil when the agent runs without a terminal (an editor's chat panel).
    public var tty: String?
    public var folder: String
    /// The tmux pane, when the agent runs inside tmux: then `tty` is a tmux client's terminal.
    public var tmux: TmuxPane?

    public init(bundleIdentifier: String, processID: Int32, tty: String?, folder: String, tmux: TmuxPane? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.tty = tty
        self.folder = folder
        self.tmux = tmux
    }

    /// The open editor folder that contains `path`, deepest first: the window to bring forward.
    public static func window(for path: String, among folders: [String]) -> String? {
        folders.filter { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    /// The session file's path.
    public let id: String
    public let kind: AgentKind
    public var project: String
    public var title: String?
    public var state: AgentState
    public var lastActivity: Date
    /// When the current stretch of work began, for "working 3m".
    public var workingSince: Date?
    public var tokens: Int
    /// The folder the agent works in.
    public var cwd: String?
    /// The editor or terminal it runs in, when its process is still alive.
    public var host: SessionHost?
    /// What it's waiting on the person for, when it needs them.
    public var request: AgentRequest?

    public init(id: String, kind: AgentKind, project: String, title: String? = nil, state: AgentState,
                lastActivity: Date, workingSince: Date? = nil, tokens: Int = 0, cwd: String? = nil, host: SessionHost? = nil,
                request: AgentRequest? = nil) {
        self.id = id
        self.kind = kind
        self.project = project
        self.title = title
        self.state = state
        self.lastActivity = lastActivity
        self.workingSince = workingSince
        self.tokens = tokens
        self.cwd = cwd
        self.host = host
        self.request = request
    }

    /// The session's id, from its file name: `<id>.jsonl` for Claude Code,
    /// `rollout-<date>-<id>.jsonl` for Codex.
    public var sessionID: String? {
        let name = URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent
        switch kind {
        case .claude:
            // It goes into a shell command, so only a real UUID may.
            return UUID(uuidString: name) == nil ? nil : name
        case .codex:
            // A UUID is 36 characters: the end of the name.
            guard name.count > 36 else { return nil }
            let uuid = String(name.suffix(36))
            return UUID(uuidString: uuid) == nil ? nil : uuid
        }
    }

    /// A shell command that picks the session up again in a terminal.
    public var resumeCommand: String? {
        guard let sessionID else { return nil }
        let resume = kind == .claude ? "claude --resume \(sessionID)" : "codex resume \(sessionID)"
        guard let cwd else { return resume }
        // Claude Code finds sessions by project folder, so start there.
        return "cd '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))' && \(resume)"
    }
}

/// What an agent is waiting on the person for, read from the end of its transcript, so the
/// island can say more than "Needs you".
public struct AgentRequest: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// A tool waits for the person to allow it.
        case permission
        /// The agent asked something and waits for the answer.
        case question
    }

    public var kind: Kind
    /// The tool's name ("Bash", "Edit"), when a tool is waiting.
    public var tool: String?
    /// One short line: the command, the file, or the question.
    public var summary: String?

    public init(kind: Kind, tool: String? = nil, summary: String? = nil) {
        self.kind = kind
        self.tool = tool
        self.summary = summary.flatMap(Self.shortened)
    }

    /// "Bash: npm test", or the question on its own.
    public var text: String {
        switch (tool, summary) {
        case let (tool?, summary?) where kind == .permission: return "\(tool): \(summary)"
        case let (_, summary?): return summary
        case let (tool?, nil): return tool
        case (nil, nil): return kind == .question ? "Has a question" : "Needs permission"
        }
    }

    /// The longest summary kept: about a line of the open island.
    public static let maxLength = 120

    /// The text on one line, trimmed and cut at `maxLength` with an ellipsis; nil when empty.
    public static func shortened(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// One rate-limit window as Codex reports it.
public struct RateLimitWindow: Codable, Equatable, Identifiable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?
    /// The model a limit of its own applies to ("Fable"), beside the limit for all models.
    public var model: String?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?, model: String? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.model = model
    }

    /// A model's week and the week for all models last as long, so the model tells them apart.
    public var id: String { model.map { "\(windowMinutes):\($0)" } ?? String(windowMinutes) }

    /// "5-hour" or "Weekly".
    public var label: String {
        switch windowMinutes {
        case 10_080: return "Weekly"
        case 1_440: return "Daily"
        // A line without `window_minutes` reads as 0: say "Limit", not "0-hour".
        case ...0: return "Limit"
        case let minutes where minutes % 60 == 0: return "\(minutes / 60)-hour"
        default: return "\(windowMinutes)-minute"
        }
    }

    /// What a meter calls it: "5 hours", "Week", "Fable week".
    public var shortLabel: String {
        if let model { return windowMinutes == 10_080 ? "\(model) week" : "\(model) \(label.lowercased())" }
        switch windowMinutes {
        case 300: return "5 hours"
        case 10_080: return "Week"
        default: return label
        }
    }

    /// A window that has reset since it was observed starts again from zero.
    public func current(at now: Date) -> RateLimitWindow {
        guard let resets = resetsAt, resets <= now else { return self }
        var window = self
        window.usedPercent = 0
        window.resetsAt = nil
        return window
    }
}

public struct CodexLimits: Equatable, Sendable {
    public var primary: RateLimitWindow?
    public var secondary: RateLimitWindow?
    public var observedAt: Date
    /// The rollout of the session that reported them.
    public var session: String?

    public init(primary: RateLimitWindow?, secondary: RateLimitWindow?, observedAt: Date, session: String? = nil) {
        self.primary = primary
        self.secondary = secondary
        self.observedAt = observedAt
        self.session = session
    }

    public var windows: [RateLimitWindow] { [primary, secondary].compactMap { $0 } }
}

/// What Claude Code logged when it ran into (or near) a usage limit.
public struct ClaudeLimitNotice: Equatable, Sendable {
    /// "rejected" means the limit was hit; other values are warnings.
    public var status: String
    /// "five_hour", "seven_day", …
    public var type: String
    public var resetsAt: Date
    public var observedAt: Date
    /// The transcript it was logged in: which session was refused.
    public var session: String?

    public init(status: String, type: String, resetsAt: Date, observedAt: Date, session: String? = nil) {
        self.status = status
        self.type = type
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.session = session
    }

    public var isLimitReached: Bool { status == "rejected" }

    /// "5-hour", "Weekly", or a model's own week ("seven_day_opus": "Opus weekly").
    public var windowLabel: String {
        switch type {
        case "five_hour": return "5-hour"
        case "seven_day": return "Weekly"
        case let other where other.hasPrefix("seven_day_"):
            return other.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized + " weekly"
        case let other: return other.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Only worth showing until the limit resets.
    public func isCurrent(at now: Date) -> Bool { resetsAt > now }
}

/// Claude Code token use: the current 5-hour window (as Claude's limits count it) and today.
public struct UsageSummary: Equatable, Sendable {
    public var windowStart: Date?
    public var windowEnd: Date?
    /// Tokens the model newly read or wrote (`window.fresh`): cache reads are left out, or
    /// they'd be most of the number. They're in `window.cacheRead`.
    public var windowTokens: Int
    public var windowRequests: Int
    /// Today's fresh tokens (`today.fresh`), cache reads apart in `today.cacheRead`.
    public var todayTokens: Int
    public var todayRequests: Int
    /// Each kind of token, for the window and today.
    public var window = TokenCounts()
    public var today = TokenCounts()
    /// What the same use would cost at API list prices: an estimate.
    public var windowCost = CostEstimate()
    public var todayCost = CostEstimate()

    public init(windowStart: Date? = nil, windowEnd: Date? = nil, windowTokens: Int = 0, windowRequests: Int = 0,
                todayTokens: Int = 0, todayRequests: Int = 0) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.windowTokens = windowTokens
        self.windowRequests = windowRequests
        self.todayTokens = todayTokens
        self.todayRequests = todayRequests
    }

    public static let empty = UsageSummary()
}
