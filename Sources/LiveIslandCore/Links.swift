import Foundation

/// Values read from `liveisland://` links. Any web page or Shortcut can open one, so each
/// value is checked here before it reaches the model.
public enum LinkValue {
    /// The longest timer a link can start: a day.
    public static let longestTimerMinutes: Double = 1_440

    /// timer/<minutes>: a positive, finite number of minutes, at most a day. "inf", "nan",
    /// "1e20" and "-5" would otherwise reach the timer and the clock that shows it.
    public static func timerMinutes(_ text: String) -> Double? {
        guard let minutes = Double(text), minutes.isFinite, minutes > 0 else { return nil }
        return min(minutes, longestTimerMinutes)
    }

    /// What switch/… asks for: the best account, or the one with claude-swap's (or
    /// ccswap's) number.
    public enum SwitchTarget: Equatable, Sendable {
        case best
        case number(Int)
    }

    /// switch/best, switch/<n>: "best" in any case, or a whole account number from 1 up.
    public static func switchTarget(_ text: String?) -> SwitchTarget? {
        guard let text else { return nil }
        if text.lowercased() == "best" { return .best }
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), number > 0 else { return nil }
        return .number(number)
    }
}
