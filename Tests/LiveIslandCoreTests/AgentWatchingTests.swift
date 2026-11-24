import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Agent tick")
struct AgentTickTests {
    private func session(_ state: AgentState) -> AgentSession {
        AgentSession(id: UUID().uuidString, kind: .claude, project: "app", state: state, lastActivity: Date())
    }

    @Test func looksQuicklyOnlyWhileSomethingHappens() {
        #expect(AgentTick.interval(for: []) == AgentTick.empty)
        #expect(AgentTick.interval(for: [session(.idle), session(.idle)]) == AgentTick.quiet)
        #expect(AgentTick.interval(for: [session(.idle), session(.working)]) == AgentTick.busy)
        #expect(AgentTick.interval(for: [session(.waiting)]) == AgentTick.busy)
        #expect(AgentTick.interval(for: [session(.done)]) == AgentTick.busy)
    }
}

@Suite("Usage summary cache")
struct UsageSummaryCacheTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    @Test func keepsTheSummaryUntilRecordsChangeOrAWindowEnds() {
        let now = Format.date(iso8601: "2026-10-22T12:00:00.000Z")!
        let windowEnd = Format.date(iso8601: "2026-10-22T15:00:00.000Z")!
        var cache = UsageSummaryCache()
        var builds = 0
        func read(_ at: Date) -> UsageSummary {
            cache.summary(now: at, calendar: utc) {
                builds += 1
                return UsageSummary(windowStart: windowEnd.addingTimeInterval(-UsageLedger.windowLength), windowEnd: windowEnd,
                                    windowTokens: 100, windowRequests: 1, todayTokens: 100, todayRequests: 1)
            }
        }
        _ = read(now)
        _ = read(now.addingTimeInterval(60))
        #expect(builds == 1)

        cache.invalidate()
        _ = read(now.addingTimeInterval(120))
        #expect(builds == 2)

        // The window ended: the summary must drop it.
        _ = read(windowEnd)
        #expect(builds == 3)
    }

    @Test func rebuildsAtMidnightAndWhenTheClockGoesBack() {
        let evening = Format.date(iso8601: "2026-10-22T23:59:00.000Z")!
        var cache = UsageSummaryCache()
        var builds = 0
        func read(_ at: Date) { _ = cache.summary(now: at, calendar: utc) { builds += 1; return .empty } }
        read(evening)
        read(evening.addingTimeInterval(30))
        #expect(builds == 1)
        read(Format.date(iso8601: "2026-10-23T00:00:01.000Z")!)
        #expect(builds == 2)
        read(evening)
        #expect(builds == 3)
    }
}

@Suite("Watch events")
struct WatchEventsTests {
    let claude = "/Users/me/.claude/projects"
    let codex = "/Users/me/.codex/sessions"

    @Test func keepsTranscriptChangesAndIgnoresOtherFiles() {
        let batch = WatchEvents.batch(
            paths: ["\(claude)/-Users-me-app/1b2c.jsonl", "\(claude)/-Users-me-app/.DS_Store", "\(codex)/2026/10/22/rollout-a.jsonl"],
            flags: [0x0001_0000, 0x0001_0000, 0x0001_0000], roots: [claude, codex])
        #expect(batch.changed == ["\(claude)/-Users-me-app/1b2c.jsonl", "\(codex)/2026/10/22/rollout-a.jsonl"])
        #expect(batch.rescan.isEmpty)
    }

    @Test func rescansTheRootHoldingAFolderToScan() {
        let batch = WatchEvents.batch(paths: ["\(codex)/2026/10/22/"], flags: [0x0000_0001], roots: [claude, codex])
        #expect(batch.rescan == [codex])
        #expect(batch.changed.isEmpty)
    }

    @Test func rescansEveryRootWhenEventsWereDropped() {
        // Dropped events name the stream's root, or "/" for the whole stream.
        let user = WatchEvents.batch(paths: ["/"], flags: [0x0000_0002 | 0x0000_0001], roots: [claude, codex])
        #expect(user.rescan == [claude, codex])
        let kernel = WatchEvents.batch(paths: ["/Users/me/"], flags: [0x0000_0004 | 0x0000_0001], roots: [claude, codex])
        #expect(kernel.rescan == [claude, codex])
        let one = WatchEvents.batch(paths: ["\(claude)/"], flags: [0x0000_0001], roots: [claude, codex])
        #expect(one.rescan == [claude])
    }
}

@Suite("Process arguments")
struct ProcessArgumentsTests {
    private func procargs(executable: String, arguments: [String], environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
        bytes += Array(executable.utf8) + [0, 0, 0, 0]
        for text in arguments + environment { bytes += Array(text.utf8) + [0] }
        return bytes + [0, 0, 0]
    }

    @Test func readsArgumentsAndEnvironment() {
        let buffer = procargs(executable: "/Users/me/.local/share/claude/versions/2.1.308", arguments: ["claude", "--resume"],
                              environment: ["TMUX=/private/tmp/tmux-501/default,4242,0", "TMUX_PANE=%3", "TERM=screen-256color"])
        let parsed = ProcessArguments.parse(buffer)
        #expect(parsed?.arguments == ["claude", "--resume"])
        #expect(parsed?.environment["TMUX_PANE"] == "%3")
        #expect(parsed?.environment["TERM"] == "screen-256color")
    }

    @Test func survivesATruncatedBuffer() {
        #expect(ProcessArguments.parse([1, 0]) == nil)
        let cut = Array(procargs(executable: "/bin/zsh", arguments: ["-zsh"], environment: []).prefix(12))
        #expect(ProcessArguments.parse(cut)?.arguments.count ?? 0 <= 1)
    }
}

@Suite("tmux")
struct TmuxTests {
    @Test func readsThePaneFromTheEnvironment() {
        let pane = TmuxPane(environment: ["TMUX": "/private/tmp/tmux-501/default,4242,0", "TMUX_PANE": "%3"])
        #expect(pane == TmuxPane(socket: "/private/tmp/tmux-501/default", serverPID: 4242, pane: "%3"))
        #expect(TmuxPane(environment: ["TMUX_PANE": "%3"]) == nil)
        #expect(TmuxPane(environment: ["TMUX": "garbage", "TMUX_PANE": "%3"]) == nil)
    }

    @Test func picksTheClientShowingThePanesSession() {
        let output = "/dev/ttys004\t$0\t1792650000\n/dev/ttys007\t$1\t1792650100\n/dev/ttys009\t$1\t1792650050\n"
        let clients = TmuxPane.clients(in: output)
        #expect(clients.count == 3)
        let shown = TmuxPane.client(for: "$1", among: clients)
        #expect(shown?.client.tty == "/dev/ttys007")
        #expect(shown?.mustSwitch == false)
    }

    @Test func switchesTheLatestClientWhenNoneShowsTheSession() {
        let clients = TmuxPane.clients(in: "/dev/ttys004\t$0\t1792650000\n/dev/ttys007\t$2\t1792650100\n")
        let shown = TmuxPane.client(for: "$5", among: clients)
        #expect(shown?.client.tty == "/dev/ttys007")
        #expect(shown?.mustSwitch == true)
        #expect(TmuxPane.client(for: "$5", among: []) == nil)
    }
}

@Suite("Editor windows")
struct EditorWindowsTests {
    private let storage = #"{"windowsState":{"lastActiveWindow":{"folder":"file:///Users/me/Code/app","backupPath":"/x"},"openedWindows":[{"workspace":{"id":"8f1e","configPath":"file:///Users/me/Code/team.code-workspace"},"backupPath":"/y"},{"folder":"file:///Users/me/Code/app"},{"folder":"vscode-remote://ssh-remote%2Bbox/home/me"}]}}"#

    @Test func readsFolderAndWorkspaceWindows() {
        let windows = EditorWindows.open(storage: Data(storage.utf8))
        #expect(windows == [.folder("/Users/me/Code/app"), .workspace("/Users/me/Code/team.code-workspace")])
    }

    @Test func readsAWorkspaceWithCommentsAndTrailingCommas() {
        let file = """
        {
            // Two projects in one window.
            "folders": [
                { "path": "api" },
                { "path": "../shared/web", },
                { "uri": "file:///Users/me/Notes" },
            ],
            "settings": {},
        }
        """
        let folders = EditorWindows.folders(inWorkspace: Data(file.utf8), at: "/Users/me/Code/team.code-workspace")
        #expect(folders == ["/Users/me/Code/api", "/Users/me/shared/web", "/Users/me/Notes"])
    }

    @Test func opensTheWorkspaceHoldingTheSessionsFolder() {
        let windows: [EditorWindows.Window] = [.folder("/Users/me/Code/app"), .workspace("/Users/me/Code/team.code-workspace")]
        let folders = { (_: String) in ["/Users/me/Code/api", "/Users/me/shared/web"] }
        #expect(EditorWindows.target(for: "/Users/me/Code/api/src", among: windows, workspaceFolders: folders)
            == "/Users/me/Code/team.code-workspace")
        #expect(EditorWindows.target(for: "/Users/me/Code/app", among: windows, workspaceFolders: folders) == "/Users/me/Code/app")
        #expect(EditorWindows.target(for: "/Users/me/Elsewhere", among: windows, workspaceFolders: folders) == nil)
    }
}
