import Foundation

/// The lengths a scroll over the timer tile steps through: by the minute while short, then in
/// bigger steps, so a day is a few flicks away and 7 minutes is still easy to land on.
public enum TimerLength {
    /// Where the first scroll starts from.
    public static let initial: Double = 5

    /// Minutes: 1…10 by 1, 15…60 by 5, 75…180 by 15, then by 30 up to a day.
    public static let ladder: [Double] = {
        var values = Array(stride(from: 1.0, through: 10, by: 1))
        values += stride(from: 15.0, through: 60, by: 5)
        values += stride(from: 75.0, through: 180, by: 15)
        values += stride(from: 210.0, through: LinkValue.longestTimerMinutes, by: 30)
        return values
    }()

    /// The length `steps` rungs above (or below, when negative) `minutes`, kept on the ladder.
    /// A length between rungs moves to the next one in that direction first.
    public static func step(_ minutes: Double, by steps: Int) -> Double {
        guard steps != 0, minutes.isFinite else { return minutes.isFinite ? minutes : initial }
        let index: Int
        if steps > 0 {
            let above = ladder.firstIndex(where: { $0 > minutes }) ?? ladder.count - 1
            index = above + steps - 1
        } else {
            let below = ladder.lastIndex(where: { $0 < minutes }) ?? 0
            index = below + steps + 1
        }
        return ladder[min(max(index, 0), ladder.count - 1)]
    }

    /// "45 min", "1 h", "1 h 30 min".
    public static func label(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total) min" }
        let hours = total / 60, rest = total % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Turns scroll deltas into whole steps. A trackpad sends many small precise deltas and a
/// wheel one line per notch, so each keeps what's left over until it adds up to a step.
public struct ScrollSteps: Sendable {
    /// Points of trackpad travel per step.
    public static let pointsPerStep: Double = 14
    /// At most this many steps from one event, so a fast flick doesn't jump to a day.
    public static let maxPerEvent = 3

    private var pending: Double = 0

    public init() {}

    /// `delta` is positive for "more" (the app flips natural scrolling first).
    public mutating func add(_ delta: Double, precise: Bool) -> Int {
        guard delta.isFinite else { return 0 }
        // Turning around starts afresh, so the first step back is as quick as the last forward.
        if pending != 0, (pending > 0) != (delta > 0) { pending = 0 }
        pending += precise ? delta / Self.pointsPerStep : delta
        let whole = Int(pending.rounded(.towardZero))
        pending -= Double(whole)
        return min(max(whole, -Self.maxPerEvent), Self.maxPerEvent)
    }

    public mutating func reset() { pending = 0 }
}
