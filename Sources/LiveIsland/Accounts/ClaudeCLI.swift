import Foundation

/// Running Claude Code the way the person would from Terminal.
enum ClaudeCLI {
    /// `claude`, wherever its installer put it. `LIVEISLAND_CLAUDE` points at a stand-in, for
    /// testing tasks without spending real usage.
    static var executable: String? {
        if let standIn = ProcessInfo.processInfo.environment["LIVEISLAND_CLAUDE"], FileManager.default.isExecutableFile(atPath: standIn) {
            return standIn
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The PATH of the person's login shell, so a task finds the same tools (git, swift, node…)
    /// it would in Terminal. An app opened from the Dock only gets the system's. Both account
    /// controllers load it at once from different tasks, so it's kept behind a lock.
    static var shellPath: String { ShellPath.shared.value }

    /// How long a login shell gets to print its PATH. A profile that waits on something (a
    /// prompt, a backgrounded job holding the terminal) would otherwise hold up the accounts.
    static let shellPathTimeout: TimeInterval = 5

    /// Asks the login shell once; later calls wait for that same answer.
    static func loadShellPath(timeout: TimeInterval = shellPathTimeout) async {
        await ShellPath.shared.load(timeout: timeout).value
    }

    /// The environment for running Claude Code: the account it uses now (claude-swap moves it),
    /// and no API key or token variable, since those outrank the login and `-p` uses an API key
    /// without asking, which would bill it silently.
    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_PROFILE",
                    "CLAUDE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"] {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = shellPath
        return environment
    }
}

/// The shell's PATH, read and written from any thread.
private final class ShellPath: @unchecked Sendable {
    static let shared = ShellPath()

    private let lock = NSLock()
    private var path = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private var loading: Task<Void, Never>?

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    func load(timeout: TimeInterval) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let loading { return loading }
        let task = Task.detached { [self] in
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            guard let data = try? await ProcessRunner.output(shell, ["-l", "-c", "printf %s \"$PATH\""], timeout: timeout),
                  let found = String(data: data, encoding: .utf8), found.contains("/usr/bin")
            else { return }
            self.set(found)
        }
        loading = task
        return task
    }

    private func set(_ found: String) {
        lock.lock()
        path = found
        lock.unlock()
    }
}
