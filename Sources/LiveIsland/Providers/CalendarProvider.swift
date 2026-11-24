import AppKit
import EventKit
import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "calendar")

/// Today's upcoming events, from every calendar the user has in Calendar.
@MainActor
final class CalendarProvider {
    struct Event: Equatable, Identifiable {
        var id: String
        var title: String
        var start: Date
        var end: Date
        var color: CGColor?
        var location: String?
        /// The Zoom, Meet, Teams or Webex link to join, from the event's URL, location or notes.
        var meetingURL: URL?

        static func == (lhs: Event, rhs: Event) -> Bool {
            lhs.id == rhs.id && lhs.title == rhs.title && lhs.start == rhs.start && lhs.end == rhs.end
                && lhs.location == rhs.location && lhs.meetingURL == rhs.meetingURL
        }
    }

    var onUpdate: (([Event]) -> Void)?
    private(set) var events: [Event] = []
    private(set) var isAuthorized = false

    /// Replaced when access is granted after launch: a store made before then can keep
    /// answering with nothing.
    private var store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var refreshTimer: Timer?

    func start() {
        // Access granted in System Settings after a denial would otherwise wait for a relaunch.
        // Coming back to LiveIsland (Settings, the menu bar panel) checks again; the check is cheap.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAccess() }
        }
        // Also every 5 minutes, since an accessory app is rarely activated.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isAuthorized { self.refresh() } else { self.checkAccess() }
            }
        }
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            checkAccess()
            return
        }
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                if granted, !isAuthorized { becameAuthorized(newStore: false) }
            } catch {
                log.error("Calendar access failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for observer in [storeObserver, activationObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        storeObserver = nil
        activationObserver = nil
    }

    /// Follows the access the user gives or takes away in System Settings, without prompting.
    private func checkAccess() {
        let granted = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        if granted, !isAuthorized {
            becameAuthorized(newStore: true)
        } else if !granted, isAuthorized {
            isAuthorized = false
            if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
            storeObserver = nil
            guard !events.isEmpty else { return }
            events = []
            onUpdate?(events)
        }
    }

    private func becameAuthorized(newStore: Bool) {
        isAuthorized = true
        if newStore { store = EKEventStore() }
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// Timed events from now until midnight tomorrow; all-day events aren't "upcoming", and
    /// neither are cancelled meetings or ones the user declined.
    func refresh() {
        guard isAuthorized else { return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3600), end: end, calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && Self.isAttending($0) }
            .sorted { $0.startDate < $1.startDate }
            .prefix(6)
            .map(Self.event)
        guard next != events else { return }
        events = Array(next)
        onUpdate?(events)
    }

    private static func isAttending(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return false }
        let me = event.attendees?.first { $0.isCurrentUser }
        return me?.participantStatus != .declined
    }

    private static func event(_ event: EKEvent) -> Event {
        // Every occurrence of a recurring event shares its identifier; the start tells them apart.
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        let id = "\(identifier)@\(Int(event.startDate.timeIntervalSince1970))"
        let link = MeetingLink.find(url: event.url, location: event.location, notes: event.notes)
        return Event(id: id, title: event.title ?? "Event", start: event.startDate, end: event.endDate,
                     color: event.calendar?.cgColor, location: event.location, meetingURL: link?.url)
    }
}
