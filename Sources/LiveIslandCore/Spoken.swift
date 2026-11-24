import Foundation

/// Words for VoiceOver, and counted phrases written out whole.
///
/// The island's own text is cut to fit beside a notch ("3m", "Bash?"); read aloud it needs
/// full words. Counted phrases come as one whole phrase per form, never a suffix glued onto a
/// word ("need\(s)"), so a translation can change every word around the number, not just one.
public enum Spoken {
    /// `one` when `count` is exactly 1, `other` otherwise. Pass both as complete phrases:
    /// `plural(n, one: "\(n) agent needs you", other: "\(n) agents need you")`.
    public static func plural(_ count: Int, one: @autoclosure () -> String, other: @autoclosure () -> String) -> String {
        count == 1 ? one() : other()
    }

    /// "1 account", "3 accounts": the common case of a number and a noun.
    public static func count(_ count: Int, _ one: String, _ other: String) -> String {
        plural(count, one: "\(count) \(one)", other: "\(count) \(other)")
    }

    /// "45 seconds", "1 minute 30 seconds", "12 minutes", "1 hour 5 minutes", "2 days 4 hours":
    /// `Format.span` in words. Under 10 minutes the seconds stay, so a timer's last minutes
    /// aren't read as a whole minute short.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        switch total {
        case ..<60: return count(total, "second", "seconds")
        case ..<600:
            let minutes = count(total / 60, "minute", "minutes"), seconds = total % 60
            return seconds == 0 ? minutes : minutes + " " + count(seconds, "second", "seconds")
        case ..<3600: return count(total / 60, "minute", "minutes")
        case ..<86_400:
            let hours = count(total / 3600, "hour", "hours"), minutes = (total % 3600) / 60
            return minutes == 0 ? hours : hours + " " + count(minutes, "minute", "minutes")
        default:
            let days = count(total / 86_400, "day", "days"), hours = (total % 86_400) / 3600
            return hours == 0 ? days : days + " " + count(hours, "hour", "hours")
        }
    }

    /// A slider's position as VoiceOver reads it: "45%".
    public static func percent(_ fraction: Double) -> String {
        let clamped = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return "\(Int((clamped * 100).rounded()))%"
    }

    /// Where an adjustable slider goes when VoiceOver swipes up or down: one `step` along,
    /// kept between 0 and 1.
    public static func stepped(_ value: Double, up: Bool, step: Double = 0.05) -> Double {
        let start = value.isFinite ? value : 0
        return min(max(start + (up ? step : -step), 0), 1)
    }
}

public extension IslandActivity {
    /// The closed island as one sentence, for VoiceOver: what the two wings say together, in
    /// words ("Claude Code working on LiveIsland, 3 minutes"). `request` is what the agent
    /// waits on, from its session. With details hidden (the screen is shared) it leaves out
    /// projects, titles, accounts and tools, like the island itself does.
    func spokenLabel(now: Date = Date(), request: AgentRequest? = nil, hidingDetails: Bool = false) -> String {
        func named(_ text: String, _ joiner: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return hidingDetails || trimmed.isEmpty ? "" : joiner + trimmed
        }
        switch self {
        case .call(let app, let since):
            return "Call in \(app), \(Spoken.duration(now.timeIntervalSince(since)))"
        case .timerFinished:
            return "Timer done"
        case .timer(let endsAt):
            return "Timer, \(Spoken.duration(endsAt.timeIntervalSince(now))) left"
        case .agentNeedsYou(let kind, let project):
            if let request, request.kind == .permission, let tool = request.tool, !tool.isEmpty, !hidingDetails {
                return "\(kind.displayName) asks to use \(tool)" + named(project, " in ")
            }
            if request?.kind == .question { return "\(kind.displayName) has a question" + named(project, " in ") }
            return "\(kind.displayName) needs you" + named(project, " in ")
        case .agentDone(let kind, let project):
            if request?.kind == .question { return "\(kind.displayName) asks you something" + named(project, " in ") }
            return "\(kind.displayName) is done" + named(project, " in ")
        case .agentWorking(let kind, let project, let since):
            return "\(kind.displayName) working" + named(project, " on ") + ", \(Spoken.duration(now.timeIntervalSince(since)))"
        case .accountLimit(let account, let switchTo):
            return hidingDetails ? "The account in use reached its limit. Another account has room"
                : "\(account) reached its limit. Switch to \(switchTo)"
        case .accountSwitched(let to):
            return "Switched accounts" + named(to, " to ")
        case .limitReset(let kind, let account):
            return "\(kind.displayName)'s limit reset" + named(account, " for ")
        case .limitWaiting(let kind, let account, let resetsAt):
            return "\(kind.displayName) is out of usage" + named(account, " on ")
                + ", back in \(Spoken.duration(resetsAt.timeIntervalSince(now)))"
        case .limitForecast(let kind, _, let runsOutAt):
            return "At this pace, \(kind.displayName) runs out in \(Spoken.duration(runsOutAt.timeIntervalSince(now)))"
        case .headphonesConnected(let name, let battery):
            return "\(name) connected" + (battery.map { ", battery \($0)%" } ?? "")
        case .charging(let percent):
            return "Charging, \(percent)%"
        case .lowBattery(let device, let percent):
            return "\(device ?? "Mac") battery low, \(percent)%"
        case .eventSoon(let title, let startsAt):
            let event = hidingDetails || title.trimmingCharacters(in: .whitespaces).isEmpty ? "Event" : title
            return startsAt > now ? "\(event) in \(Spoken.duration(startsAt.timeIntervalSince(now)))" : "\(event) now"
        case .cameraOn(let app):
            return "Camera in use" + (app.map { " by \($0)" } ?? "")
        case .microphoneOn(let app):
            return "Microphone in use by \(app)"
        case .nowPlaying(let title, let isPlaying):
            let verb = isPlaying ? "Playing" : "Paused"
            return hidingDetails || title.trimmingCharacters(in: .whitespaces).isEmpty ? verb : "\(verb): \(title)"
        }
    }
}
