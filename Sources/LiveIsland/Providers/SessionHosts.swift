import AppKit
import Darwin
import LiveIslandCore

/// Finds the running Claude Code and Codex processes: the folder each started in, the terminal
/// it's attached to, and the app around it (VS Code, Cursor, Antigravity, Terminal…), so the
/// island can jump straight to a session. Inside tmux or screen the app is the terminal showing
/// one of the server's clients.
enum SessionHosts {
    struct Found {
        var kind: AgentKind
        var host: SessionHost
    }

    /// A terminal multiplexer's client: the process in a terminal tab showing a tmux or screen session.
    private struct Client {
        var name: String
        var tty: String
        var app: (bundleIdentifier: String, pid: pid_t)
    }

    private static let multiplexers: Set<String> = ["tmux", "screen"]

    /// One read of the whole process table, then a few calls per agent found.
    static func scan() -> [Found] {
        var parents: [pid_t: pid_t] = [:]
        var names: [pid_t: String] = [:]
        var agents: [(pid: pid_t, kind: AgentKind, tty: String?)] = []
        var clientProcesses: [(pid: pid_t, name: String, tty: String)] = []
        for process in allProcesses() {
            let pid = process.kp_proc.p_pid
            parents[pid] = process.kp_eproc.e_ppid
            let name = name(of: process)
            names[pid] = name
            let tty = tty(of: process)
            if multiplexers.contains(name) {
                // The server runs detached; a client sits in a terminal tab.
                if let tty { clientProcesses.append((pid, name, tty)) }
                continue
            }
            let kind: AgentKind
            switch name {
            case "claude": kind = .claude
            case "codex": kind = .codex
            // Claude Code's native install runs ~/.local/share/claude/versions/2.1.308, so the
            // kernel calls it "2.1.308"; it's still started as "claude".
            case _ where isVersionNumber(name) && firstArgument(of: pid).map({ ($0 as NSString).lastPathComponent }) == "claude":
                kind = .claude
            default: continue
            }
            agents.append((pid, kind, tty))
        }

        // Looked up only when an agent turns out to run inside tmux or screen.
        var clients: [Client]?
        func multiplexerClients() -> [Client] {
            if let clients { return clients }
            let found = clientProcesses.compactMap { process in
                hostApp(of: process.pid, parents: parents).map { Client(name: process.name, tty: process.tty, app: $0) }
            }
            clients = found
            return found
        }

        var found: [Found] = []
        for agent in agents {
            guard let folder = workingDirectory(of: agent.pid) else { continue }
            if let app = hostApp(of: agent.pid, parents: parents) {
                found.append(Found(kind: agent.kind, host: SessionHost(bundleIdentifier: app.bundleIdentifier, processID: app.pid,
                                                                       tty: agent.tty, folder: folder)))
            } else if let multiplexer = multiplexer(of: agent.pid, parents: parents, names: names),
                      let client = multiplexerClients().first(where: { $0.name == multiplexer }) {
                // The server has no app around it, so use a terminal showing one of its clients.
                // With several clients, the one showing the pane is found when the session is tapped.
                let pane = multiplexer == "tmux" ? tmuxVariables(of: agent.pid).flatMap(TmuxPane.init(environment:)) : nil
                found.append(Found(kind: agent.kind, host: SessionHost(bundleIdentifier: client.app.bundleIdentifier,
                                                                       processID: client.app.pid, tty: client.tty,
                                                                       folder: folder, tmux: pane)))
            }
        }
        return found
    }

    /// The terminal app showing the tmux client attached to `tty`.
    static func tmuxClientApp(tty: String) -> (bundleIdentifier: String, pid: pid_t)? {
        var parents: [pid_t: pid_t] = [:]
        var client: pid_t?
        for process in allProcesses() {
            let pid = process.kp_proc.p_pid
            parents[pid] = process.kp_eproc.e_ppid
            if name(of: process) == "tmux", self.tty(of: process) == tty { client = pid }
        }
        return client.flatMap { hostApp(of: $0, parents: parents) }
    }

    /// The executable a process runs, such as tmux's server: the same tmux talks to it.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func name(of process: kinfo_proc) -> String {
        var comm = process.kp_proc.p_comm
        return withUnsafeBytes(of: &comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func tty(of process: kinfo_proc) -> String? {
        let device = process.kp_eproc.e_tdev
        guard device != -1, let path = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: path)
    }

    /// "tmux" or "screen", when one of the agent's ancestors is that server.
    private static func multiplexer(of pid: pid_t, parents: [pid_t: pid_t], names: [pid_t: String]) -> String? {
        var current = parents[pid]
        for _ in 0..<16 {
            guard let process = current, process > 1 else { return nil }
            if let name = names[process], multiplexers.contains(name) { return name }
            current = parents[process]
        }
        return nil
    }

    private static func isVersionNumber(_ name: String) -> Bool {
        !name.isEmpty && name.contains(".") && name.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// The kernel's copy of the process's arguments and environment.
    private static func processArguments(of pid: pid_t) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(Array(buffer.prefix(size)))
    }

    /// argv[0].
    private static func firstArgument(of pid: pid_t) -> String? {
        processArguments(of: pid)?.arguments.first
    }

    /// Only `TMUX` and `TMUX_PANE` are kept from the agent's environment: the rest can hold secrets.
    private static func tmuxVariables(of pid: pid_t) -> [String: String]? {
        guard let process = processArguments(of: pid) else { return nil }
        var variables: [String: String] = [:]
        for key in ["TMUX", "TMUX_PANE"] { variables[key] = process.value(of: key) }
        return variables
    }

    /// Every process, with its parent and terminal; unlike per-process calls this also covers
    /// root's processes, such as the `login` between Terminal and its shell.
    private static func allProcesses() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        size += size / 4  // Room for processes started in between.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty || path == "/" ? nil : path
    }

    /// The nearest ancestor that is a regular app: the shell's terminal, or the editor whose
    /// helper process runs the integrated terminal.
    private static func hostApp(of pid: pid_t, parents: [pid_t: pid_t]) -> (bundleIdentifier: String, pid: pid_t)? {
        var current = parents[pid]
        for _ in 0..<16 {
            guard let process = current, process > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: process), app.activationPolicy == .regular,
               let bundle = app.bundleIdentifier {
                return (bundle, process)
            }
            current = parents[process]
        }
        return nil
    }
}

/// Bringing a session's app forward, as close to the session as each app allows.
@MainActor
enum SessionJump {
    /// Editors built on VS Code keep their open windows in a JSON file under Application Support.
    static let editors: [String: String] = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.google.antigravity": "Antigravity",
        "com.exafunction.windsurf": "Windsurf",
        "com.vscodium": "VSCodium",
    ]

    /// Asking tmux which client shows a pane waits on a process, so it runs off the main thread.
    private static let tmuxQueue = DispatchQueue(label: "com.aissam.liveisland.jump.tmux", qos: .userInitiated)

    static func go(to host: SessionHost, cwd: String?) {
        if let support = editors[host.bundleIdentifier] {
            openEditorWindow(host, support: support, cwd: cwd)
        } else if let pane = host.tmux {
            tmuxQueue.async {
                let shown = Tmux.show(pane)
                DispatchQueue.main.async {
                    var target = host
                    if let shown {
                        target.tty = shown.tty
                        if let app = shown.app {
                            target.bundleIdentifier = app.bundleIdentifier
                            target.processID = app.pid
                        }
                    }
                    jumpToTerminal(target)
                }
            }
        } else {
            jumpToTerminal(host)
        }
    }

    private static func jumpToTerminal(_ host: SessionHost) {
        guard let tty = host.tty, let script = terminalScript(for: host.bundleIdentifier, tty: tty),
              NSRunningApplication(processIdentifier: host.processID) != nil
        else { return activate(host) }
        AppleScriptQueue.shared.async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error != nil { DispatchQueue.main.async { activate(host) } }
        }
    }

    private static func activate(_ host: SessionHost) {
        NSRunningApplication(processIdentifier: host.processID)?.activate()
    }

    /// Opening a folder or workspace that's already open in the editor brings its window
    /// forward. Opening anything else would make a new window, so then just bring the editor forward.
    private static func openEditorWindow(_ host: SessionHost, support: String, cwd: String?) {
        let windows = openWindows(support: support)
        let target = [cwd, host.folder].compactMap { $0 }.lazy.compactMap {
            EditorWindows.target(for: $0, among: windows, workspaceFolders: workspaceFolders)
        }.first
        guard let target, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleIdentifier) else {
            return activate(host)
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: target)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func openWindows(support: String) -> [EditorWindows.Window] {
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(support)/User/globalStorage/storage.json")
        return (try? Data(contentsOf: file)).map(EditorWindows.open(storage:)) ?? []
    }

    private static func workspaceFolders(_ file: String) -> [String] {
        (try? Data(contentsOf: URL(fileURLWithPath: file))).map { EditorWindows.folders(inWorkspace: $0, at: file) } ?? []
    }

    /// Terminal and iTerm2 can select the exact tab by its terminal device.
    private static func terminalScript(for bundle: String, tty: String) -> String? {
        switch bundle {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
                activate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                            end if
                        end repeat
                    end repeat
                end repeat
                activate
            end tell
            """
        default:
            return nil
        }
    }
}

/// Talking to the tmux server an agent runs under, with the server's own executable and socket.
private enum Tmux {
    struct Shown {
        var tty: String
        var app: (bundleIdentifier: String, pid: pid_t)?
    }

    /// Makes `pane` the current one in its window and session, and in a client: one already on
    /// that session, else the most recent client, which switches to it. Returns that client.
    static func show(_ pane: TmuxPane) -> Shown? {
        guard let tmux = SessionHosts.executablePath(of: pane.serverPID),
              let session = run(tmux, pane, ["display-message", "-p", "-t", pane.pane, "#{session_id}"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !session.isEmpty,
              let list = run(tmux, pane, ["list-clients", "-F", TmuxPane.clientFormat]),
              let (client, mustSwitch) = TmuxPane.client(for: session, among: TmuxPane.clients(in: list))
        else { return nil }
        _ = run(tmux, pane, ["select-window", "-t", pane.pane])
        _ = run(tmux, pane, ["select-pane", "-t", pane.pane])
        if mustSwitch { _ = run(tmux, pane, ["switch-client", "-c", client.tty, "-t", pane.pane]) }
        return Shown(tty: client.tty, app: SessionHosts.tmuxClientApp(tty: client.tty))
    }

    /// Runs one tmux command, giving up after two seconds so a stuck server can't hold the queue.
    private static func run(_ tmux: String, _ pane: TmuxPane, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmux)
        process.arguments = ["-S", pane.socket] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
