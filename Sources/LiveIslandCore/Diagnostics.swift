import Foundation

/// Whose an `auto` loop running on this Mac is, for the Accounts page's diagnostics: two loops
/// switching the same accounts fight each other, so one besides LiveIsland's is worth a word.
public enum AutoLoopOwner: Equatable, Sendable {
    /// The loop this LiveIsland runs.
    case liveIsland
    /// A loop an earlier LiveIsland started and left behind (it's ended at the next launch).
    case leftOver
    /// One started some other way, from Terminal or claude-swap's own menu bar app.
    case someoneElse

    /// `parent` is the loop's parent process, `ownPID` this app's; `marked` whether it carries
    /// LiveIsland's mark (`AutoLoopMark`).
    public static func of(parent: Int32, ownPID: Int32, marked: Bool) -> AutoLoopOwner {
        if parent == ownPID { return .liveIsland }
        return marked ? .leftOver : .someoneElse
    }
}

/// What the diagnostics card says about the shell's PATH: the folders the installers use, and
/// whether they're in it, since a tool installed there is otherwise "not found".
public struct PathReport: Equatable, Sendable {
    public let folders: [String]
    /// The folders tools are looked for in that the PATH lacks.
    public let missing: [String]

    public init(path: String, expected: [String]) {
        var seen = Set<String>()
        folders = path.split(separator: ":").map(String.init).filter { !$0.isEmpty && seen.insert($0).inserted }
        let present = Set(folders.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 })
        missing = expected.filter { !present.contains($0) }
    }
}
