import Foundation

/// When an account that ran out can work again.
public enum LimitWait {
    /// When every account-wide limit it reached has reset; nil while it has room, or when a
    /// limit it reached doesn't say when it resets. A model's own week stops only that model, so
    /// it doesn't count.
    public static func backAt(_ account: ClaudeAccount, at now: Date) -> Date? {
        let reached = [account.fiveHour, account.sevenDay].compactMap { $0?.current(at: now) }.filter { $0.usedPercent >= 100 }
        guard !reached.isEmpty else { return nil }
        let resets = reached.compactMap(\.resetsAt)
        guard resets.count == reached.count else { return nil }
        return resets.max()
    }

    /// With no account to switch to: the one that comes back first, among the one in use and
    /// those that could be switched to, and when.
    public static func firstBack(_ accounts: [ClaudeAccount], at now: Date) -> (account: ClaudeAccount, at: Date)? {
        accounts
            .filter { $0.isActive || ($0.switcher != nil && !$0.needsLogin) }
            .compactMap { account in backAt(account, at: now).map { (account, $0) } }
            .min { $0.1 < $1.1 }
    }
}

/// Notices the moment the account in use comes back from its limit, to say so once.
///
/// It's fed whatever is known about the account in use, whenever that changes and on the
/// island's clock. Only a reset counts: switching to another account isn't the limit coming
/// back (that has its own notice), and numbers that dip before the reset time are more likely
/// a stale reading than the limit lifting, so they don't count either.
public struct LimitReturn: Sendable {
    /// The account seen at its limit, and when it said it would reset.
    private var waiting: (id: String, backAt: Date)?
    /// Readings may come from a clock a little off from this one.
    public static let grace: TimeInterval = 120

    public init() {}

    /// True once, on the first reading after the account's limit reset.
    public mutating func observe(_ account: ClaudeAccount?, at now: Date) -> Bool {
        guard let account else {
            waiting = nil
            return false
        }
        if account.current(at: now).isAtLimit {
            if let back = LimitWait.backAt(account, at: now) {
                waiting = (account.id, back)
            } else if waiting?.id != account.id {
                waiting = nil
            }
            return false
        }
        defer { waiting = nil }
        guard let waiting, waiting.id == account.id else { return false }
        return now >= waiting.backAt.addingTimeInterval(-Self.grace)
    }
}

/// When the account in use runs out at the pace it's going, if that's before its limit resets.
public enum LimitForecast {
    /// How long before running out the closed notch starts to say so.
    public static let lead: TimeInterval = 90 * 60
    /// A pace measured over less than this is mostly noise.
    static let minimumElapsed: TimeInterval = 15 * 60
    /// Below this, a few replies more or less change the answer by hours.
    static let minimumUsed: Double = 10

    /// From the average pace since the window began: a 5-hour window starts with its first
    /// reply, so its average is the pace of this stretch of work.
    public static func runsOut(_ window: RateLimitWindow, at now: Date) -> Date? {
        guard window.windowMinutes > 0, let resets = window.resetsAt, resets > now,
              window.usedPercent >= minimumUsed, window.usedPercent < 100
        else { return nil }
        let started = resets.addingTimeInterval(-TimeInterval(window.windowMinutes) * 60)
        let elapsed = now.timeIntervalSince(started)
        guard elapsed >= minimumElapsed else { return nil }
        let perSecond = window.usedPercent / elapsed
        let out = now.addingTimeInterval((100 - window.usedPercent) / perSecond)
        return out < resets ? out : nil
    }

    /// The first of the account's limits to run out. For the week, claude-swap's own
    /// projection wins when it has one: it sees the recent pace, not just the week's average.
    /// - Parameters:
    ///   - projected: claude-swap's `projectedExhaustionAt` for the week.
    ///   - willLastToReset: claude-swap's `willLastToReset` for the week.
    public static func runsOut(_ account: ClaudeAccount, projected: Date? = nil, willLastToReset: Bool? = nil,
                               at now: Date) -> Date? {
        let current = account.current(at: now)
        guard !current.isAtLimit else { return nil }
        var candidates: [Date] = []
        if let fiveHour = current.fiveHour, let out = runsOut(fiveHour, at: now) { candidates.append(out) }
        switch willLastToReset {
        case false?:
            if let projected, projected > now { candidates.append(projected) }
            else if let week = current.sevenDay, let out = runsOut(week, at: now) { candidates.append(out) }
        case true?:
            break
        case nil:
            if let week = current.sevenDay, let out = runsOut(week, at: now) { candidates.append(out) }
        }
        return candidates.min()
    }

    /// Whether it's near enough to show in the closed notch.
    public static func isNear(_ runsOut: Date, at now: Date) -> Bool {
        runsOut > now && runsOut.timeIntervalSince(now) <= lead
    }
}

/// Opening the island by itself for a moment, like the iPhone's island when something
/// happens: only when nothing more important is on, nobody is using it, and not too often,
/// since an open island takes the clicks under it.
public struct BriefOpen: Sendable {
    /// How long it stays open.
    public static let duration: TimeInterval = 2
    /// The least time between two brief opens: several agents finishing in a row open it once.
    public static let cooldown: TimeInterval = 30

    /// What's going on when a moment happens.
    public struct Conditions: Sendable {
        public var enabled: Bool
        /// Accessibility's Reduce Motion: the moment still shows in the closed notch.
        public var reduceMotion: Bool
        public var expanded: Bool
        public var hovering: Bool
        /// Being moved, hidden over a full-screen app, or nobody at the screen.
        public var unavailable: Bool
        /// Something more important than the moment is on (a call, a finished timer).
        public var outranked: Bool

        public init(enabled: Bool, reduceMotion: Bool, expanded: Bool, hovering: Bool, unavailable: Bool, outranked: Bool) {
            self.enabled = enabled
            self.reduceMotion = reduceMotion
            self.expanded = expanded
            self.hovering = hovering
            self.unavailable = unavailable
            self.outranked = outranked
        }
    }

    private var lastOpened: Date?

    public init() {}

    /// Whether to open now; remembers it when so.
    public mutating func shouldOpen(_ conditions: Conditions, at now: Date) -> Bool {
        guard conditions.enabled, !conditions.reduceMotion, !conditions.expanded, !conditions.hovering,
              !conditions.unavailable, !conditions.outranked
        else { return false }
        if let lastOpened, now.timeIntervalSince(lastOpened) < Self.cooldown, now >= lastOpened { return false }
        lastOpened = now
        return true
    }
}
