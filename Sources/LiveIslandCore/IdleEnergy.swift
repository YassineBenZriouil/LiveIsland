import Foundation

/// Whether the island's 30-second clock needs to redraw it. Each bump redraws the whole island,
/// so it happens only while something on screen changes with time alone: an event coming up,
/// a limit waiting to reset, a timer or a call.
public enum ClockTicks {
    /// How often the clock is checked.
    public static let interval: TimeInterval = 30
    /// An event shows from this long before it starts…
    public static let eventLead: TimeInterval = 600
    /// …until this long after.
    public static let eventTail: TimeInterval = 120

    /// Whether an event is "soon" at `now`, as the closed notch shows it.
    public static func isSoon(_ start: Date, at now: Date) -> Bool {
        start.timeIntervalSince(now) < eventLead && now.timeIntervalSince(start) < eventTail
    }

    /// Whether anything time-based was showing at the last bump or has come up since.
    /// - Parameters:
    ///   - last: when the clock last redrew the island.
    ///   - eventStarts: the start of each upcoming event the island may show.
    ///   - limitShown: an account at its limit is on screen; it goes away when the limit resets.
    public static func needed(since last: Date, now: Date, timerRunning: Bool, inCall: Bool,
                              limitShown: Bool, eventStarts: [Date]) -> Bool {
        if timerRunning || inCall || limitShown { return true }
        // An event's window [start − lead, start + tail] overlaps the time since the last bump:
        // it's showing, came up, or just ended and must go.
        return eventStarts.contains { $0.addingTimeInterval(-eventLead) <= now && $0.addingTimeInterval(eventTail) >= last }
    }
}

/// Remembers lookups that are slow and rarely change (where an app is installed), misses too,
/// so a view can ask on every redraw. Misses expire sooner: an app can be installed any time.
public struct LookupCache<Key: Hashable, Value> {
    private struct Entry {
        var value: Value?
        var expires: Date
    }

    private var entries: [Key: Entry] = [:]
    public let hitLifetime: TimeInterval
    public let missLifetime: TimeInterval

    public init(hitLifetime: TimeInterval, missLifetime: TimeInterval) {
        self.hitLifetime = hitLifetime
        self.missLifetime = missLifetime
    }

    /// The remembered answer for `key`, or `lookup`'s, kept for next time.
    public mutating func value(for key: Key, at now: Date, lookup: (Key) -> Value?) -> Value? {
        if let entry = entries[key], entry.expires > now { return entry.value }
        let value = lookup(key)
        entries[key] = Entry(value: value, expires: now.addingTimeInterval(value == nil ? missLifetime : hitLifetime))
        return value
    }

    /// Forgets every miss, so the next ask looks again (after an app launches, say).
    public mutating func forgetMisses() {
        entries = entries.filter { $0.value.value != nil }
    }

    public mutating func removeAll() { entries.removeAll() }
}
