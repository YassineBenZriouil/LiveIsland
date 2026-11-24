import Foundation

/// Whether anyone can see the screen right now, from the system's sleep, display, lock and
/// user-switch notifications.
///
/// Each cause is kept apart because they end separately: the displays can wake behind a locked
/// screen, and a fast user switch can happen while the displays stay lit. Anything that only
/// matters on screen (the waveform, the clock) pauses while `isAway`.
public struct ScreenPresence: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        case systemWillSleep, systemDidWake
        case displaysDidSleep, displaysDidWake
        case screenLocked, screenUnlocked
        case sessionResigned, sessionActivated
    }

    public private(set) var isSystemAsleep = false
    public private(set) var areDisplaysAsleep = false
    public private(set) var isScreenLocked = false
    public private(set) var isSessionInactive = false

    public init(screenLocked: Bool = false) {
        isScreenLocked = screenLocked
    }

    /// Nobody can see the island: the Mac or its displays sleep, the screen is locked, or
    /// another user has the screen.
    public var isAway: Bool {
        isSystemAsleep || areDisplaysAsleep || isScreenLocked || isSessionInactive
    }

    /// Whether the Mac itself sleeps (not only its displays), for work that should stop entirely.
    public var isAsleep: Bool { isSystemAsleep }

    /// Applies one notification; returns whether `isAway` changed.
    @discardableResult
    public mutating func apply(_ event: Event) -> Bool {
        let wasAway = isAway
        switch event {
        case .systemWillSleep: isSystemAsleep = true
        case .systemDidWake: isSystemAsleep = false
        case .displaysDidSleep: areDisplaysAsleep = true
        // A lit display means the Mac is awake too, even if its wake notice was missed.
        case .displaysDidWake: areDisplaysAsleep = false; isSystemAsleep = false
        case .screenLocked: isScreenLocked = true
        case .screenUnlocked: isScreenLocked = false
        case .sessionResigned: isSessionInactive = true
        case .sessionActivated: isSessionInactive = false
        }
        return wasAway != isAway
    }
}

/// When the waveform's tap has to be built again because its output device changed under it.
///
/// The tap is tied to one output device at one sample rate. AirPods switching to the call
/// codec change the rate (48 kHz to 16 or 24 kHz), and an unplugged device stops being alive;
/// either way the old tap goes quiet, so it's rebuilt. A rate that only wobbles is not a change.
public enum TapRebuild {
    public static func isNeeded(builtAt builtRate: Double, nowAt nominalRate: Double?, isAlive: Bool) -> Bool {
        guard isAlive else { return true }
        guard let nominalRate, nominalRate > 0 else { return false }
        return abs(nominalRate - builtRate) > 0.5
    }
}
