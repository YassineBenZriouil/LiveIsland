import CoreGraphics
import Foundation

/// Placing the island: a press of ⌘ on its own sets it down. ⌘ as part of a shortcut (⌘-Tab,
/// ⌘C) doesn't, and neither does a ⌘ already held when placing began until it's let go.
///
/// Fed by polling, since other apps' key presses can't be watched without a permission: the
/// caller passes whether ⌘ is down and whether anything else is held with it.
public struct CommandTap: Equatable, Sendable {
    /// ⌘ has been up since placing began, so the next press counts.
    private var armed: Bool
    private var down = false
    /// Something else was pressed, or held, during this press.
    private var chorded = false

    public init(commandDown: Bool) {
        armed = !commandDown
    }

    /// Returns true when a lone press of ⌘ ends: that's the moment to set the island down.
    public mutating func update(commandDown: Bool, otherKeysDown: Bool) -> Bool {
        switch (down, commandDown) {
        case (false, true):
            guard armed else { return false }
            down = true
            chorded = otherKeysDown
            return false
        case (true, true):
            if otherKeysDown { chorded = true }
            return false
        case (true, false):
            down = false
            return !chorded
        case (false, false):
            armed = true
            return false
        }
    }

    /// Something happened during the press that a poll can't see, like another app coming to
    /// the front (⌘-Tab), so this press is a shortcut.
    public mutating func noteShortcut() {
        if down { chorded = true }
    }
}

/// One window, as `CGWindowListCopyWindowInfo` describes it (top-left origin).
public struct ScreenWindow: Equatable, Sendable {
    public var ownerPID: Int32
    public var ownerName: String
    public var layer: Int
    public var bounds: CGRect

    public init(ownerPID: Int32, ownerName: String, layer: Int, bounds: CGRect) {
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.layer = layer
        self.bounds = bounds
    }

    /// Reads one entry of the window list; nil when it lacks what's needed.
    public init?(info: [String: Any]) {
        guard let pid = (info["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
              let layer = (info["kCGWindowLayer"] as? NSNumber)?.intValue,
              let bounds = info["kCGWindowBounds"] as? [String: Any],
              let x = (bounds["X"] as? NSNumber)?.doubleValue, let y = (bounds["Y"] as? NSNumber)?.doubleValue,
              let width = (bounds["Width"] as? NSNumber)?.doubleValue, let height = (bounds["Height"] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(ownerPID: pid, ownerName: info["kCGWindowOwnerName"] as? String ?? "", layer: layer,
                  bounds: CGRect(x: x, y: y, width: width, height: height))
    }
}

/// Whether an app is full screen on a display: one of its ordinary windows covers the whole
/// display, menu bar included. A zoomed window stops under the menu bar, so it doesn't count.
public enum FullScreen {
    public static func covers(_ display: CGRect, windows: [ScreenWindow], ignoring ownPID: Int32) -> Bool {
        windows.contains { window in
            window.layer == 0 && window.ownerPID != ownPID
                && window.bounds.insetBy(dx: -1, dy: -1).contains(display)
        }
    }
}

/// Signs that the screen is being shared or recorded, from what can be seen without a
/// permission: apps that only run, or only show a window, while they capture the screen.
/// No public API says "the screen is being recorded", so this covers the common cases and
/// Settings offers to hide details all the time for the rest.
public enum ScreenSharing {
    /// Processes whose windows appear only while they capture: macOS's screenshot and screen
    /// recording toolbar, and Zoom's screen-share helper.
    public static let capturingWindowOwners: Set<String> = ["screencaptureui", "CptHost"]
    /// Apps that exist to record or stream the screen.
    public static let capturingApps: Set<String> = [
        "com.obsproject.obs-studio", "com.loom.desktop", "com.apple.screencaptureui", "us.zoom.CptHost",
    ]

    public static func isSharing(windows: [ScreenWindow], runningApps: [String]) -> Bool {
        windows.contains { capturingWindowOwners.contains($0.ownerName) }
            || runningApps.contains(where: capturingApps.contains)
    }
}

/// Where the pointer is, for an idle island at the top edge of a display without a notch.
/// There's nothing drawn there, so it never catches clicks (the menu bar's middle keeps
/// working); pushing the pointer against the top edge over it, and keeping it there, opens it.
public enum TopEdgeHotSpot {
    /// How close to the top edge the pointer has to be, in points.
    public static let reach: CGFloat = 2
    /// How long it has to stay, so moving to the menu bar doesn't open the island.
    public static let dwell: TimeInterval = 0.45

    /// `area` is the invisible island's frame, `screenTop` the display's top (bottom-left origin).
    public static func contains(_ point: CGPoint, area: CGRect, screenTop: CGFloat) -> Bool {
        point.y >= screenTop - reach && point.y <= screenTop + 1
            && point.x >= area.minX && point.x <= area.maxX
    }
}

public extension IslandActivity {
    /// What stays on screen over a full-screen app when the island hides there: a call or a
    /// timer is worth seeing even during a film.
    var showsOverFullScreen: Bool {
        switch self {
        case .call, .timer, .timerFinished: return true
        default: return false
        }
    }
}
