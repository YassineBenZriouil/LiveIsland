import Foundation

/// Keeps a call going through short microphone drops. Calling apps let go of the mic for a
/// moment when they switch devices or reconnect, and ending the call right away would restart
/// its timer when the mic comes back.
public struct CallTracker: Equatable, Sendable {
    /// How long the mic can be gone before the call counts as over.
    public static let grace: TimeInterval = 4

    public private(set) var call: (app: String, since: Date)?
    /// When the calling app was last seen holding the mic.
    private var lastSeen: Date?

    public init() {}

    /// The call after this reading of the mic: `app` is the calling app holding it, if any.
    @discardableResult
    public mutating func update(app: String?, at now: Date) -> (app: String, since: Date)? {
        if let app {
            if call?.app != app { call = (app, now) }
            lastSeen = now
        } else if let lastSeen, now.timeIntervalSince(lastSeen) < Self.grace {
            // Still within the grace period: keep the call as it is.
        } else {
            call = nil
            lastSeen = nil
        }
        return call
    }

    /// When to look again so a call that lost the mic ends on time; nil while nothing is pending.
    public func endCheck(after now: Date, micHeld: Bool) -> Date? {
        guard call != nil, !micHeld, let lastSeen else { return nil }
        return max(now, lastSeen.addingTimeInterval(Self.grace))
    }

    public static func == (lhs: CallTracker, rhs: CallTracker) -> Bool {
        lhs.call?.app == rhs.call?.app && lhs.call?.since == rhs.call?.since && lhs.lastSeen == rhs.lastSeen
    }
}

/// Decides when a battery level is worth announcing: the Mac's at 20% and 10% while on battery,
/// fully charged while plugged in, and headphones at 20% and 10%. Each one is said once, and
/// only when the level gets there, never for the level found at launch or on connecting.
public struct BatteryAlerts: Equatable, Sendable {
    public static let lowLevels = [20, 10]

    public enum Alert: Equatable, Sendable {
        case low(percent: Int)
        case full
    }

    private var lastMac: (percent: Int, full: Bool)?
    private var lastHeadphones: [String: Int] = [:]

    public init() {}

    /// What the Mac's new reading is worth saying.
    public mutating func mac(percent: Int, onPower: Bool, isFull: Bool) -> Alert? {
        defer { lastMac = (percent, isFull) }
        guard let last = lastMac else { return nil }
        if onPower {
            return isFull && !last.full ? .full : nil
        }
        return Self.crossed(from: last.percent, to: percent).map { .low(percent: $0) }
    }

    /// The low level a pair of headphones just reached, if any. `percent` is their lowest earbud.
    public mutating func headphones(_ name: String, percent: Int?) -> Int? {
        guard let percent else { return nil }
        defer { lastHeadphones[name] = percent }
        guard let last = lastHeadphones[name] else { return nil }
        return Self.crossed(from: last, to: percent)
    }

    /// Headphones that disconnected start over: their next connection is a fresh first reading.
    public mutating func forgetHeadphones(_ name: String) {
        lastHeadphones[name] = nil
    }

    /// The lowest threshold passed on the way down from `old` to `new`.
    static func crossed(from old: Int, to new: Int) -> Int? {
        lowLevels.filter { old > $0 && new <= $0 }.min()
    }

    public static func == (lhs: BatteryAlerts, rhs: BatteryAlerts) -> Bool {
        lhs.lastMac?.percent == rhs.lastMac?.percent && lhs.lastMac?.full == rhs.lastMac?.full
            && lhs.lastHeadphones == rhs.lastHeadphones
    }
}

/// Browsers and chat apps record from a helper process ("Google Chrome Helper", WebKit's GPU
/// process), whose name means nothing to the user. Finds the app it belongs to.
public enum HelperApps {
    /// The running app whose bundle identifier `helper`'s extends, the longest match winning
    /// ("com.google.Chrome.helper" belongs to "com.google.Chrome").
    public static func owner(of helper: String, among apps: [String]) -> String? {
        apps.filter { helper.count > $0.count && helper.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
    }
}

/// Battery levels per connected Bluetooth device, from `system_profiler SPBluetoothDataType -json`.
public struct HeadphoneBattery: Equatable, Sendable {
    public var left: Int?
    public var right: Int?
    public var single: Int?
    public var caseLevel: Int?

    public init(left: Int? = nil, right: Int? = nil, single: Int? = nil, caseLevel: Int? = nil) {
        self.left = left
        self.right = right
        self.single = single
        self.caseLevel = caseLevel
    }

    /// The levels of the connected device called `name`, or nil if the report doesn't list it.
    public static func parse(_ report: Data, name: String) -> HeadphoneBattery? {
        guard let root = try? JSONSerialization.jsonObject(with: report) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]]
        else { return nil }
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                guard let info = entry[name] as? [String: Any] else { continue }
                func level(_ key: String) -> Int? {
                    (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) }
                }
                return HeadphoneBattery(left: level("device_batteryLevelLeft"), right: level("device_batteryLevelRight"),
                                        single: level("device_batteryLevelMain"), caseLevel: level("device_batteryLevelCase"))
            }
        }
        return nil
    }
}
