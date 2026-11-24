import Foundation

enum AppleScriptQueue { static let shared = DispatchQueue(label: "com.aissam.liveisland.applescript", qos: .userInitiated) }
