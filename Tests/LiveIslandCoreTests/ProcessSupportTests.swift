import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Scripts, restarts and loops")
struct ProcessSupportTests {
    // MARK: Quoting

    @Test func quotingKeepsANameAsText() {
        #expect(Shell.quoted("Work") == "'Work'")
        #expect(Shell.quoted("Bob's") == #"'Bob'\''s'"#)
        #expect(Shell.quoted("$(rm -rf ~) \"x\"") == #"'$(rm -rf ~) "x"'"#)
        #expect(Shell.echo("Sign in to “A”") == #"printf '%s\n' 'Sign in to “A”'"#)
    }

    @Test func quotedNamesSurviveARealShell() throws {
        let name = #"Wo"rk $(echo hacked) `id` 'x' \n"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Shell.echo(name)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: output, as: UTF8.self) == name + "\n")
    }

    // MARK: Backoff

    @Test func waitsLongerAfterEachQuickStop() {
        var backoff = RestartBackoff()
        #expect(backoff.delay(afterRunning: 3) == 5)
        #expect(backoff.delay(afterRunning: 40) == 15)
        #expect(backoff.delay(afterRunning: nil) == 60)  // didn't even start
        #expect(backoff.delay(afterRunning: 1) == 300)
        #expect(backoff.delay(afterRunning: 1) == 300)
    }

    @Test func aLongRunStartsOverButOneEventDoesNot() {
        var backoff = RestartBackoff()
        _ = backoff.delay(afterRunning: 2)
        _ = backoff.delay(afterRunning: 2)
        // Nine minutes isn't long enough to count as healthy.
        #expect(backoff.delay(afterRunning: 540) == 60)
        #expect(backoff.delay(afterRunning: 601) == 5)
        _ = backoff.delay(afterRunning: 2)
        backoff.reset()
        #expect(backoff.failures == 0)
        #expect(backoff.delay(afterRunning: 2) == 5)
    }

    // MARK: Process arguments

    /// Shaped like the kernel's answer for `python3 /Users/x/.local/bin/ccswap codex auto --json`.
    private static func procargs(_ arguments: [String], environment: [String], path: String = "/usr/bin/python3") -> Data {
        var data = Data()
        var count = Int32(arguments.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(contentsOf: Array(path.utf8) + [0, 0, 0, 0])
        for argument in arguments { data.append(contentsOf: Array(argument.utf8) + [0]) }
        for variable in environment { data.append(contentsOf: Array(variable.utf8) + [0]) }
        data.append(0)
        data.append(contentsOf: Array("ptr_munge=".utf8) + [0] + Array("executable_path=/usr/bin/python3".utf8) + [0])
        return data
    }

    @Test func readsArgumentsAndEnvironment() throws {
        let data = Self.procargs(["python3", "/Users/x/.local/bin/ccswap", "codex", "auto", "--json"],
                                 environment: ["HOME=/Users/x/Library/Application Support/LiveIsland/ccswap", "LIVEISLAND_AUTO_LOOP=ccswap", "NO_COLOR=1"])
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(parsed.arguments == ["python3", "/Users/x/.local/bin/ccswap", "codex", "auto", "--json"])
        #expect(parsed.environment.count == 3)
        #expect(parsed.value(of: "NO_COLOR") == "1")
        #expect(parsed.value(of: "NO") == nil)
        #expect(AutoLoopMark.isLiveIslands(parsed, tool: "ccswap"))
        #expect(!AutoLoopMark.isLiveIslands(parsed, tool: "cswap"))
    }

    @Test func aLoopThePersonStartedIsntOurs() throws {
        let data = Self.procargs(["python3", "/Users/x/.local/bin/ccswap", "codex", "auto", "--json"],
                                 environment: ["HOME=/Users/x", "TERM=xterm-256color"])
        let parsed = try #require(ProcessArguments.parse(data))
        #expect(!AutoLoopMark.isLiveIslands(parsed, tool: "ccswap"))
    }

    @Test func eitherMarkMakesALoopOurs() throws {
        let hidden = ProcessArguments(arguments: ["/usr/bin/python3", "/Users/x/.local/bin/ccswap", "codex", "auto", "--json"], environment: [])
        let marked = ProcessArguments(arguments: hidden.arguments, environment: ["LIVEISLAND_AUTO_LOOP=ccswap"])
        let recorded = AutoLoopMark.pids(in: "4242\n")
        #expect(recorded == [4242])
        #expect(AutoLoopMark.isLiveIslands(pid: 4242, started: hidden, recorded: recorded, tool: "ccswap"))
        #expect(AutoLoopMark.isLiveIslands(pid: 7, started: marked, recorded: recorded, tool: "ccswap"))
        #expect(!AutoLoopMark.isLiveIslands(pid: 7, started: hidden, recorded: recorded, tool: "ccswap"))
        #expect(!AutoLoopMark.isLiveIslands(pid: 7, started: nil, recorded: [], tool: "ccswap"))
        #expect(AutoLoopMark.pids(in: "x\n1\n0\n  99 \n") == [99])
    }

    @Test func rejectsCutOffAnswers() {
        #expect(ProcessArguments.parse(Data()) == nil)
        #expect(ProcessArguments.parse(Data([2, 0, 0, 0])) == nil)
        var data = Data([3, 0, 0, 0])
        data.append(contentsOf: Array("/bin/x".utf8) + [0, 0] + Array("x".utf8) + [0])
        #expect(ProcessArguments.parse(data) == nil)
    }
}
