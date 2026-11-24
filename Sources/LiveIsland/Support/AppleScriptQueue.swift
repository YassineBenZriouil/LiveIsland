import Foundation

/// The one queue every `NSAppleScript` runs on. AppleScript isn't safe to run on two threads
/// at once (it can crash inside the Open Scripting Architecture), so the players and session
/// jumps take turns here.
enum AppleScriptQueue {
    static let shared = DispatchQueue(label: "com.aissam.liveisland.applescript", qos: .userInitiated)
}
