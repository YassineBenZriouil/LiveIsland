import Foundation

/// AppleScript for Spotify and Music that can't open them. Checking that an app runs before
/// sending a script leaves a gap: the person can quit it in between, and the script would
/// launch it again. A script that asks for itself, as it runs, has no gap.
public enum PlayerScript {
    /// `body`, run only while the app is open; otherwise `fallback` (what a closed app answers).
    public static func guarded(_ body: String, app bundleIdentifier: String, otherwise fallback: String = "") -> String {
        guard isBundleIdentifier(bundleIdentifier) else { return fallback }
        return """
        if application id "\(bundleIdentifier)" is running then
        \(body)
        end if
        \(fallback)
        """
    }

    /// What a player's change notice says it's doing. Spotify and Music both name it under
    /// "Player State"; a "Stopped" usually means the app is quitting, so asking it anything
    /// then could bring it back.
    public enum NoticeState: Equatable, Sendable { case playing, paused, stopped, unknown }

    public static func state(ofNotice userInfo: [AnyHashable: Any]?) -> NoticeState {
        switch (userInfo?["Player State"] as? String)?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: .unknown
        }
    }

    /// Only plain identifiers go inside the script's quotes.
    static func isBundleIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}
