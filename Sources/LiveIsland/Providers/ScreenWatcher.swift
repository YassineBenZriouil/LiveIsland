import AppKit
import CoreGraphics
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "presence")

/// Tells the island when nobody can see the screen (sleep, displays off, locked, another user)
/// and when the Mac wakes, so on-screen work can pause and time-based work can catch up.
@MainActor
final class ScreenWatcher {
    var onChange: ((ScreenPresence) -> Void)?
    /// After the Mac wakes: deadlines counted in uptime missed the time asleep.
    var onWake: (() -> Void)?
    private(set) var presence = ScreenPresence()
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    func start() {
        guard tokens.isEmpty else { return }
        presence = ScreenPresence(screenLocked: Self.isScreenLockedNow)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification, .systemWillSleep)
        observe(workspace, NSWorkspace.didWakeNotification, .systemDidWake)
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displaysDidSleep)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displaysDidWake)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResigned)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionActivated)
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
        onChange?(presence)
    }

    func stop() {
        for (center, token) in tokens { center.removeObserver(token) }
        tokens = []
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: ScreenPresence.Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.receive(event) }
        }
        tokens.append((center, token))
    }

    private func receive(_ event: ScreenPresence.Event) {
        let changed = presence.apply(event)
        if changed { log.notice("Screen \(self.presence.isAway ? "away" : "back", privacy: .public) (\(String(describing: event), privacy: .public))") }
        if event == .systemDidWake { onWake?() }
        if changed || event == .systemWillSleep || event == .systemDidWake { onChange?(presence) }
    }

    /// Whether the login window covers the screen now, for a launch behind a locked screen.
    private static var isScreenLockedNow: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
