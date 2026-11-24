import AppKit
import Darwin
import LiveIslandCore
import SwiftUI

/// What the Accounts page's diagnostics card found: the shell's PATH, the installers, the
/// switchers, jq and the status line, and any `auto` loop besides LiveIsland's own. Checked
/// only when the card is opened or asked again, never in the background.
@MainActor
final class Diagnostics: ObservableObject {
    struct Row: Identifiable {
        enum State { case good, warning, info }
        let id: String
        let title: String
        let detail: String
        let state: State
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isChecking = false
    @Published private(set) var checkedAt: Date?
    /// Whether the card is open (kept here: SwiftUI's @State needs Xcode's plugins).
    @Published var isExpanded = false

    func check(claude: ClaudeSwapController, codex: CodexSwapController) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            await ClaudeCLI.loadShellPath()
            var rows = [pathRow(), installerRow(),
                        toolRow(id: "cswap", name: "claude-swap", path: claude.executable, version: claude.version),
                        toolRow(id: "ccswap", name: "ccswap", path: codex.executable, version: codex.version),
                        claudeRow(), jqRow(), statusLineRow()]
            rows.append(await loopRow(id: "cswap-loop", name: "cswap auto", pattern: "(^|[/ ])cswap auto", mark: nil))
            rows.append(await loopRow(id: "ccswap-loop", name: "ccswap codex auto", pattern: "ccswap codex auto", mark: "ccswap"))
            self.rows = rows
            checkedAt = Date()
            isChecking = false
        }
    }

    /// The card as plain text, for a bug report. Paths only: no account, no token.
    var report: String {
        rows.map { "\($0.state == .good ? "ok" : $0.state == .warning ? "!!" : "--") \($0.title): \($0.detail)" }
            .joined(separator: "\n")
    }

    // MARK: - The checks

    private static func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func pathRow() -> Row {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var expected = ["\(home)/.local/bin"]
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin") { expected.append("/opt/homebrew/bin") }
        let report = PathReport(path: ClaudeCLI.shellPath, expected: expected)
        if report.missing.isEmpty {
            return Row(id: "path", title: "Shell PATH", detail: "\(report.folders.count) folders, with \(expected.map(Self.tilde).joined(separator: " and "))", state: .good)
        }
        return Row(id: "path", title: "Shell PATH",
                   detail: "\(report.missing.map(Self.tilde).joined(separator: " and ")) isn't in your shell's PATH. LiveIsland still looks there, but Terminal won't find tools installed in it (uv tool update-shell adds it).",
                   state: .warning)
    }

    private func installerRow() -> Row {
        let found = [("uv", PythonTools.find("uv")), ("pipx", PythonTools.find("pipx"))].compactMap { name, path in
            path.map { "\(name) at \(Self.tilde($0))" }
        }
        if found.isEmpty {
            return Row(id: "installer", title: "uv or pipx", detail: "Neither is installed. Install and Set Up installs uv first, from docs.astral.sh/uv.", state: .info)
        }
        return Row(id: "installer", title: "uv or pipx", detail: found.joined(separator: " · "), state: .good)
    }

    private func toolRow(id: String, name: String, path: String?, version: String?) -> Row {
        guard let path else { return Row(id: id, title: name, detail: "Not installed", state: .info) }
        return Row(id: id, title: name, detail: [version, Self.tilde(path)].compactMap { $0 }.joined(separator: " · "), state: .good)
    }

    private func claudeRow() -> Row {
        guard let claude = ClaudeCLI.executable else {
            return Row(id: "claude", title: "Claude Code", detail: "claude isn't in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin, so Sign In… can't open its sign-in.", state: .warning)
        }
        return Row(id: "claude", title: "Claude Code", detail: Self.tilde(claude), state: .good)
    }

    private func jqRow() -> Row {
        if let note = ClaudeStatusLine.missingJQNote { return Row(id: "jq", title: "jq", detail: note, state: .warning) }
        return Row(id: "jq", title: "jq", detail: "Installed: the status line lines can pass Claude's limits on", state: .good)
    }

    private func statusLineRow() -> Row {
        let title = "Status line"
        do {
            let script = try ClaudeStatusLine.script()
            if ClaudeStatusLine.needsUpdate {
                return Row(id: "statusline", title: title, detail: "\(Self.tilde(script.path)) has an earlier version's lines: update them in Settings › AI Agents.", state: .warning)
            }
            if ClaudeStatusLine.isInstalled {
                return Row(id: "statusline", title: title, detail: "LiveIsland's lines are in \(Self.tilde(script.path))", state: .good)
            }
            return Row(id: "statusline", title: title, detail: "\(Self.tilde(script.path)) doesn't pass the limits on yet: add the lines in Settings › AI Agents.", state: .info)
        } catch {
            return Row(id: "statusline", title: title, detail: error.localizedDescription, state: .info)
        }
    }

    /// The `auto` loops running now, and whose each one is. Another loop on the same accounts
    /// switches against LiveIsland's, so it's worth knowing about.
    private func loopRow(id: String, name: String, pattern: String, mark: String?) async -> Row {
        let output = (try? await ProcessRunner.output("/usr/bin/pgrep", ["-f", pattern], timeout: 5)) ?? Data()
        let pids = String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        let own = getpid()
        var others: [String] = []
        var ours = false
        for pid in pids {
            guard let parent = Self.parent(of: pid) else { continue }
            // An orphan is handed to launchd; LiveIsland's mark says the rest.
            let marked = parent == 1 || (mark.flatMap { mark in Self.arguments(of: pid).map { AutoLoopMark.isLiveIslands($0, tool: mark) } } ?? false)
            switch AutoLoopOwner.of(parent: parent, ownPID: own, marked: marked) {
            case .liveIsland: ours = true
            case .leftOver: others.append("PID \(pid), left running, likely by an earlier LiveIsland: it's ended at the next launch")
            case .someoneElse: others.append("PID \(pid), started outside LiveIsland (Terminal or a menu bar app)")
            }
        }
        if others.isEmpty {
            return Row(id: id, title: name, detail: ours ? "Only LiveIsland's loop is running" : "Not running", state: .good)
        }
        return Row(id: id, title: name,
                   detail: "Another loop switches these accounts too: " + others.joined(separator: "; ") + ". Two loops switch against each other; keep one.",
                   state: .warning)
    }

    private static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(info.pbi_ppid)
    }

    private static func arguments(of pid: Int32) -> ProcessArguments? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return ProcessArguments.parse(Data(buffer.prefix(size)))
    }
}

/// The diagnostics, as a card that opens on a click and checks then.
struct DiagnosticsCard: View {
    @ObservedObject var diagnostics: Diagnostics
    let claude: ClaudeSwapController
    let codex: CodexSwapController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { diagnostics.isExpanded.toggle() }
                if diagnostics.isExpanded { diagnostics.check(claude: claude, codex: codex) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stethoscope").foregroundStyle(.secondary)
                    Text("Diagnostics").font(.system(size: 12.5, weight: .semibold))
                    if !diagnostics.isExpanded, warnings > 0 {
                        Tag(text: "\(warnings) to look at", color: .orange)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(diagnostics.isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("PATH, uv and pipx, the switchers, jq, the status line and auto loops")
            if diagnostics.isExpanded {
                if diagnostics.rows.isEmpty {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                ForEach(diagnostics.rows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: symbol(row.state)).foregroundStyle(color(row.state)).font(.system(size: 11))
                            .frame(width: 14)
                        Text(row.title).font(.system(size: 11.5, weight: .medium)).frame(width: 120, alignment: .leading)
                        Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 12) {
                    Button("Check Again") { diagnostics.check(claude: claude, codex: codex) }
                        .disabled(diagnostics.isChecking)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.report, forType: .string)
                    }
                    .disabled(diagnostics.rows.isEmpty)
                    if diagnostics.isChecking { ProgressView().controlSize(.mini) }
                    Spacer()
                    if let at = diagnostics.checkedAt {
                        Text("Checked \(at.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11.5))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(Card())
    }

    private var warnings: Int { diagnostics.rows.filter { $0.state == .warning }.count }

    private func symbol(_ state: Diagnostics.Row.State) -> String {
        switch state {
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ state: Diagnostics.Row.State) -> Color {
        switch state {
        case .good: return .green
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}
