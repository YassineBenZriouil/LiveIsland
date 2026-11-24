import Foundation

/// How often the agent monitor looks again when no file changed. Sessions change state with
/// time alone (working → waiting → idle), so a busy one needs a quick look; with nothing listed
/// only limits expire, and file events wake the monitor the moment a session starts.
public enum AgentTick {
    /// While a session is working, waiting or just done.
    public static let busy: TimeInterval = 2
    /// While every listed session is idle: they only drop off the list after half an hour.
    public static let quiet: TimeInterval = 30
    /// With no sessions at all.
    public static let empty: TimeInterval = 60

    public static func interval(for sessions: [AgentSession]) -> TimeInterval {
        if sessions.isEmpty { return empty }
        return sessions.contains { $0.state != .idle } ? busy : quiet
    }
}

/// The usage summary, kept until a record arrives or a boundary passes: the end of the current
/// 5-hour window, or midnight for "today". Rebuilding it walks every record of the last day.
public struct UsageSummaryCache {
    private var summary: UsageSummary?
    private var computedAt: Date?
    private var validUntil: Date?

    public init() {}

    /// Records changed: the next read rebuilds.
    public mutating func invalidate() {
        summary = nil
    }

    public mutating func summary(now: Date, calendar: Calendar = .current, build: () -> UsageSummary) -> UsageSummary {
        // A clock set back could make a later boundary look unpassed; rebuild then too.
        if let summary, let computedAt, let validUntil, now >= computedAt, now < validUntil {
            return summary
        }
        let fresh = build()
        let midnight = calendar.dateInterval(of: .day, for: now)?.end ?? now.addingTimeInterval(3600)
        summary = fresh
        computedAt = now
        validUntil = min(fresh.windowEnd ?? midnight, midnight)
        return fresh
    }
}

/// What FSEvents says about a batch of events, reduced to what the monitor acts on.
public enum WatchEvents {
    /// `kFSEventStreamEventFlagMustScanSubDirs`, `…UserDropped`, `…KernelDropped`: events were
    /// coalesced or lost, so the folder named must be looked through again.
    public static let mustScanFlags: UInt32 = 0x0000_0001 | 0x0000_0002 | 0x0000_0004

    public struct Batch: Equatable {
        /// Transcript files that changed.
        public var changed: [String] = []
        /// Watched roots that must be looked through again.
        public var rescan: Set<String> = []
    }

    public static func batch(paths: [String], flags: [UInt32], roots: [String]) -> Batch {
        var batch = Batch()
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? flags[index] : 0
            if flag & mustScanFlags != 0 {
                // The path is the folder to scan; it's under a root, or above them all when dropped.
                let folder = path.hasSuffix("/") ? String(path.dropLast()) : path
                let hit = roots.filter { folder == $0 || folder.hasPrefix($0 + "/") || $0.hasPrefix(folder + "/") }
                batch.rescan.formUnion(hit.isEmpty ? roots : hit)
            } else if path.hasSuffix(".jsonl") {
                batch.changed.append(path)
            }
        }
        return batch
    }
}

/// The tmux pane an agent runs in, from its `TMUX` and `TMUX_PANE` variables, so a tap can find
/// the terminal showing it and select it there.
public struct TmuxPane: Equatable, Sendable {
    /// The server's socket, such as "/private/tmp/tmux-501/default".
    public var socket: String
    public var serverPID: Int32
    /// "%3".
    public var pane: String

    public init(socket: String, serverPID: Int32, pane: String) {
        self.socket = socket
        self.serverPID = serverPID
        self.pane = pane
    }

    /// `TMUX` is "socket,server pid,session index".
    public init?(environment: [String: String]) {
        guard let value = environment["TMUX"], let pane = environment["TMUX_PANE"], pane.hasPrefix("%") else { return nil }
        let parts = value.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts[0].isEmpty, let pid = Int32(parts[1]) else { return nil }
        self.init(socket: String(parts[0]), serverPID: pid, pane: pane)
    }

    /// The format for `tmux list-clients -F`: tty, session and last activity, tab-separated.
    public static let clientFormat = "#{client_tty}\t#{session_id}\t#{client_activity}"

    public struct Client: Equatable, Sendable {
        public var tty: String
        public var session: String
        public var activity: Int
    }

    public static func clients(in output: String) -> [Client] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[0].hasPrefix("/dev/") else { return nil }
            return Client(tty: String(fields[0]), session: String(fields[1]),
                          activity: fields.count > 2 ? Int(fields[2]) ?? 0 : 0)
        }
    }

    /// The terminal to bring forward: the most recently used client already showing the
    /// pane's session, else the most recently used one (which then switches to it).
    public static func client(for session: String, among clients: [Client]) -> (client: Client, mustSwitch: Bool)? {
        let showing = clients.filter { $0.session == session }
        if let best = showing.max(by: { $0.activity < $1.activity }) { return (best, false) }
        return clients.max(by: { $0.activity < $1.activity }).map { ($0, true) }
    }
}

/// The windows a VS Code–style editor has open, from its `storage.json`, and the folders a
/// `.code-workspace` window holds.
public enum EditorWindows {
    public enum Window: Equatable, Sendable {
        case folder(String)
        /// A multi-root workspace, by the path of its `.code-workspace` file.
        case workspace(String)
    }

    public static func open(storage data: Data) -> [Window] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = object["windowsState"] as? [String: Any]
        else { return [] }
        let entries = [windows["lastActiveWindow"]].compactMap { $0 } + ((windows["openedWindows"] as? [Any]) ?? [])
        var seen: [Window] = []
        for case let entry as [String: Any] in entries {
            let window: Window?
            if let folder = entry["folder"] as? String {
                window = fileURL(folder).map(Window.folder)
            } else if let workspace = entry["workspace"] as? [String: Any], let config = workspace["configPath"] as? String {
                window = fileURL(config).map(Window.workspace)
            } else {
                window = nil
            }
            if let window, !seen.contains(window) { seen.append(window) }
        }
        return seen
    }

    /// The folders a workspace file lists, made absolute. It's JSON with comments and trailing commas.
    public static func folders(inWorkspace data: Data, at path: String) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any],
              let folders = object["folders"] as? [[String: Any]]
        else { return [] }
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        return folders.compactMap { folder in
            if let relative = folder["path"] as? String {
                let url = relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : base.appendingPathComponent(relative)
                return url.standardizedFileURL.path
            }
            return (folder["uri"] as? String).flatMap(fileURL)
        }
    }

    /// What to open to bring forward the window holding `path`: the deepest folder that contains
    /// it, or the workspace file that holds such a folder.
    public static func target(for path: String, among windows: [Window], workspaceFolders: (String) -> [String]) -> String? {
        var candidates: [(folder: String, open: String)] = []
        for window in windows {
            switch window {
            case .folder(let folder): candidates.append((folder, folder))
            case .workspace(let file): candidates += workspaceFolders(file).map { ($0, file) }
            }
        }
        guard let folder = SessionHost.window(for: path, among: candidates.map(\.folder)) else { return nil }
        return candidates.first { $0.folder == folder }?.open
    }

    private static func fileURL(_ text: String) -> String? {
        guard let url = URL(string: text), url.isFileURL else { return nil }
        return url.standardizedFileURL.path
    }
}
