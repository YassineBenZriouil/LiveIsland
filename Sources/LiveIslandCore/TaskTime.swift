import Foundation

/// Times for accounts (when a limit resets, when a week runs out) in the person's own clock:
/// 12 or 24 hours as their settings say, with the time zone where there's room, so a reset
/// isn't misread. Making a `DateFormatter` is slow and these are asked for on every redraw,
/// so one is kept per pattern until `reset()` (the app calls it when the locale changes).
public final class TaskTimeFormat: @unchecked Sendable {
    private let locale: Locale
    private let timeZone: TimeZone
    private let lock = NSLock()
    private var formatters: [String: DateFormatter] = [:]

    public init(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) {
        self.locale = locale
        self.timeZone = timeZone
    }

    /// "15:40 CET" (or "3:40 PM CET") today, "Wed 3 Dec, 15:40 CET" another day.
    public func text(_ date: Date, now: Date = Date()) -> String {
        format(date, template: isSameDay(date, now) ? "jmmz" : "EEEdMMMjmmz")
    }

    /// For the island, where there's little room: "15:40", or "Wed 03:40" another day.
    public func short(_ date: Date, now: Date = Date()) -> String {
        format(date, template: isSameDay(date, now) ? "jmm" : "EEEjmm")
    }

    /// Forgets the patterns, so the next time follows a changed 12/24-hour setting or language.
    public func reset() {
        lock.lock()
        formatters.removeAll()
        lock.unlock()
    }

    private func isSameDay(_ date: Date, _ now: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.isDate(date, inSameDayAs: now)
    }

    private func format(_ date: Date, template: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let formatter = formatters[template] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        // The locale picks the order and the hour cycle (the person's 12/24-hour setting is
        // part of the current locale), so "j" becomes "HH" or "h … a".
        formatter.setLocalizedDateFormatFromTemplate(template)
        formatters[template] = formatter
        return formatter.string(from: date)
    }
}
