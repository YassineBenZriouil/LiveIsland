import CoreServices
import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "agents")

/// Watches Claude Code and Codex sessions through their transcripts. No setup or hooks:
/// macOS file events say which file changed, and only the new bytes are read.
@MainActor
final class AgentMonitor {
    struct Snapshot: Equatable {
        var sessions: [AgentSession] = []
        var usage: UsageSummary?
        var claudeLimit: ClaudeLimitNotice?
        var codexLimits: CodexLimits?
        /// Claude Code's own 5-hour and weekly percentages, when the status line shares them.
        var claudeLimits: ClaudeUsageLimits?
        /// Claude Code use per day for the last 30 days, oldest first and ending today, per
        /// model and project, with estimated cost.
        var usageHistory: [UsageDay] = []
        /// Codex tokens today and per day (30 days, oldest first), from its running totals.
        var codexTodayTokens: Int?
        var codexHistory: [CodexUsageDay] = []
    }

    var onUpdate: ((Snapshot) -> Void)?
    private(set) var snapshot = Snapshot()

    private let worker = Worker()
    private var stream: FSEventStreamRef?
    /// The roots the stream watches; a root made later joins when the retry finds it.
    private var watchedRoots: [String] = []
    /// Looks for roots that didn't exist yet, every half minute, until both are watched.
    private var rootRetry: Timer?
    private var tick: Timer?
    private var tickInterval: TimeInterval = 0
    private var running = false
    /// Roots already queued for a rescan, so a burst of dropped events reads each once.
    private var rescanning: Set<String> = []

    nonisolated static let claudeRoot = home.appendingPathComponent(".claude/projects")
    nonisolated static let codexRoot = home.appendingPathComponent(".codex/sessions")

    /// Where the agents keep their sessions: the home folder, or a folder of example sessions
    /// (`LIVEISLAND_AGENT_HOME`) for tests and screenshots.
    nonisolated static let home: URL = ProcessInfo.processInfo.environment["LIVEISLAND_AGENT_HOME"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser

    func start() {
        worker.queue.async { [worker] in
            worker.loadRecent()
            let next = worker.snapshot(now: Date())
            DispatchQueue.main.async { self.publish(next) }
        }
        running = true
        startWatching()
        // States also change with time alone (working → waiting → idle).
        schedule(every: AgentTick.busy)
    }

    func stop() {
        running = false
        tick?.invalidate()
        tick = nil
        tickInterval = 0
        rootRetry?.invalidate()
        rootRetry = nil
        stopStream()
    }

    private func refresh(changed paths: [String]) {
        worker.queue.async { [worker] in
            worker.ingest(paths)
            let next = worker.snapshot(now: Date())
            DispatchQueue.main.async { self.publish(next) }
        }
    }

    /// Looks through whole roots again: after FSEvents dropped events, or when a root first appears.
    private func rescan(_ roots: Set<String>) {
        let fresh = roots.subtracting(rescanning)
        guard !fresh.isEmpty else { return }
        rescanning.formUnion(fresh)
        log.notice("Looking through \(fresh.count) session folders again")
        worker.queue.async { [worker] in
            for root in fresh { worker.rescan(root: root) }
            let next = worker.snapshot(now: Date())
            DispatchQueue.main.async {
                self.rescanning.subtract(fresh)
                self.publish(next)
            }
        }
    }

    private func publish(_ next: Snapshot) {
        // With nothing listed there's little to watch for, so look much less often.
        schedule(every: AgentTick.interval(for: next.sessions))
        guard next != snapshot else { return }
        snapshot = next
        onUpdate?(next)
    }

    private func schedule(every interval: TimeInterval) {
        guard running, interval != tickInterval else { return }
        tick?.invalidate()
        tickInterval = interval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(changed: []) }
        }
        // Slow ticks don't need to be on the dot; letting them drift saves wake-ups.
        timer.tolerance = interval >= AgentTick.quiet ? interval / 4 : 0.2
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func startWatching() {
        let roots = [Self.claudeRoot, Self.codexRoot].map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        watchedRoots = roots
        watchForMissingRoots()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info, count > 0 else { return }
            let monitor = Unmanaged<AgentMonitor>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flagList = (0..<count).map { UInt32(flags[$0]) }
            MainActor.assumeIsolated {
                let batch = WatchEvents.batch(paths: list, flags: flagList, roots: monitor.watchedRoots)
                if !batch.rescan.isEmpty { monitor.rescan(batch.rescan) }
                if !batch.changed.isEmpty { monitor.refresh(changed: batch.changed) }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, callback, &context, roots as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopStream() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// Claude Code or Codex may be installed after LiveIsland starts. Watching the home folder
    /// for that would wake on every file saved there, so check for the folder now and then:
    /// one `stat` each half minute, and none once both are watched.
    private func watchForMissingRoots() {
        rootRetry?.invalidate()
        rootRetry = nil
        guard watchedRoots.count < 2 else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkForNewRoots() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        rootRetry = timer
    }

    private func checkForNewRoots() {
        let roots = [Self.claudeRoot, Self.codexRoot].map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        let added = Set(roots).subtracting(watchedRoots)
        guard !added.isEmpty else { return }
        log.notice("Started watching \(added.count) new session folders")
        stopStream()
        startWatching()
        // Sessions may have been written before the stream started.
        rescan(added)
    }
}

/// Everything that touches the transcripts, on one background queue.
private final class Worker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.aissam.liveisland.agents", qos: .utility)
    private var ledger = UsageLedger()
    private var codexLedger = CodexUsageLedger()
    private var lastLedgerSave = Date()
    private var ledgerReady = false
    /// Session files seen recently, with what their tails said.
    private var sessions: [String: Session] = [:]
    private var codexLimits: CodexLimits?
    private var lastPrune = Date()

    private struct Session {
        var kind: AgentKind
        var modified: Date
        var claudeTail: ClaudeTranscript.Tail?
        var codexTail: CodexRollout.Tail?
        var codexCwd: String?
    }

    /// How long a quiet session stays listed.
    private static let recent: TimeInterval = 30 * 60
    private static let tailBytes = 256 * 1024

    func loadRecent() {
        let now = Date()
        loadLedgers(now: now)
        let claudeFiles = Self.files(under: AgentMonitor.claudeRoot, modifiedSince: now.addingTimeInterval(-UsageLedger.horizon))
        let start = Date()
        ledger.ingest(claudeFiles.map(\.url), now: now, concurrency: 4)
        ledgerReady = true
        log.notice("Read \(claudeFiles.count) Claude transcripts in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")

        let codexFiles = Self.files(under: AgentMonitor.codexRoot, modifiedSince: now.addingTimeInterval(-7 * 86_400))
        codexLedger.ingest(codexFiles.filter { now.timeIntervalSince($0.modified) < UsageLedger.horizon }.map(\.url), now: now)
        // The newest Codex file holds the latest limits, even if the session is old.
        if let newest = codexFiles.max(by: { $0.modified < $1.modified }) { readCodex(newest.url, modified: newest.modified) }
        for file in claudeFiles + codexFiles where now.timeIntervalSince(file.modified) < Self.recent {
            update(file.url.path, modified: file.modified)
        }
    }

    func ingest(_ paths: [String]) {
        for path in Set(paths) {
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
                sessions[path] = nil
                continue
            }
            if path.hasPrefix(AgentMonitor.claudeRoot.path), ledgerReady {
                ledger.ingest(URL(fileURLWithPath: path))
                summaryCache.invalidate()
            }
            update(path, modified: modified)
        }
    }

    /// Reads a root's recent files again, for when file events were lost or the root is new.
    /// The ledger reads only what each file gained, so files it already knows cost a `stat`.
    func rescan(root: String) {
        let now = Date()
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let isClaude = root == AgentMonitor.claudeRoot.path
        let files = Self.files(under: url, modifiedSince: now.addingTimeInterval(isClaude ? -UsageLedger.horizon : -Self.recent))
        if isClaude, ledgerReady {
            ledger.ingest(files.map(\.url), now: now, concurrency: 4)
            summaryCache.invalidate()
        }
        for file in files where now.timeIntervalSince(file.modified) < Self.recent {
            update(file.url.path, modified: file.modified)
        }
    }

    /// Rebuilt only when records arrive or a window or day ends: the island looks every few seconds.
    private var summaryCache = UsageSummaryCache()

    private var hosts: (claude: [String: SessionHost], codex: [String: SessionHost]) = ([:], [:])
    private var lastHostScan = Date.distantPast

    /// Which app each running agent lives in, keyed the way sessions are filed: Claude Code
    /// by project folder name, Codex by folder. One with a terminal wins over one without.
    private func refreshHosts(now: Date) {
        guard now.timeIntervalSince(lastHostScan) > 5 else { return }
        lastHostScan = now
        var claude: [String: SessionHost] = [:]
        var codex: [String: SessionHost] = [:]
        for found in SessionHosts.scan() {
            func keep(_ existing: SessionHost?) -> Bool { existing == nil || (existing?.tty == nil && found.host.tty != nil) }
            switch found.kind {
            case .claude:
                let key = ClaudeTranscript.projectKey(for: found.host.folder)
                if keep(claude[key]) { claude[key] = found.host }
            case .codex:
                if keep(codex[found.host.folder]) { codex[found.host.folder] = found.host }
            }
        }
        let summary = (claude.values.map(\.bundleIdentifier) + codex.values.map(\.bundleIdentifier)).sorted().joined(separator: ", ")
        if summary != lastHostSummary {
            log.notice("Agents running in: \(summary.isEmpty ? "nothing" : summary, privacy: .public)")
            lastHostSummary = summary
        }
        hosts = (claude, codex)
    }
    private var lastHostSummary = ""

    func snapshot(now: Date) -> AgentMonitor.Snapshot {
        saveLedgersIfNeeded(now: now)
        sessions = sessions.filter { now.timeIntervalSince($0.value.modified) < Self.recent }
        // The process table matters only to place a session; with none, skip reading it.
        if !sessions.isEmpty { refreshHosts(now: now) }
        var list: [AgentSession] = []
        for (path, session) in sessions {
            switch session.kind {
            case .claude:
                guard let tail = session.claudeTail else { continue }
                let state = ClaudeTranscript.state(of: tail, modified: session.modified, now: now)
                list.append(AgentSession(
                    id: path, kind: .claude,
                    project: ClaudeTranscript.projectName(cwd: tail.cwd, fallback: Self.claudeProjectFallback(path)),
                    title: tail.title, state: state, lastActivity: tail.lastTimestamp ?? session.modified,
                    workingSince: state == .working || state == .waiting ? tail.turnStartedAt : nil, cwd: tail.cwd,
                    host: hosts.claude[URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent],
                    request: ClaudeTranscript.request(of: tail, state: state)))
            case .codex:
                guard let tail = session.codexTail else { continue }
                let state = CodexRollout.state(of: tail, modified: session.modified, now: now)
                list.append(AgentSession(
                    id: path, kind: .codex,
                    project: ClaudeTranscript.projectName(cwd: session.codexCwd ?? tail.cwd, fallback: "Codex"),
                    state: state, lastActivity: tail.lastEventAt ?? session.modified,
                    workingSince: tail.working ? tail.turnStartedAt : nil, tokens: tail.tokens ?? 0,
                    cwd: session.codexCwd ?? tail.cwd, host: (session.codexCwd ?? tail.cwd).flatMap { hosts.codex[$0] },
                    request: CodexRollout.request(of: tail, state: state)))
            }
        }
        list.sort { lhs, rhs in
            let order: [AgentState: Int] = [.waiting: 0, .working: 1, .done: 2, .idle: 3]
            return order[lhs.state]! != order[rhs.state]! ? order[lhs.state]! < order[rhs.state]! : lhs.lastActivity > rhs.lastActivity
        }
        if now.timeIntervalSince(lastPrune) > 600 {
            ledger.prune(now: now)
            summaryCache.invalidate()
            lastPrune = now
        }
        return AgentMonitor.Snapshot(
            sessions: list,
            usage: ledgerReady ? summaryCache.summary(now: now) { ledger.summary(now: now) } : nil,
            claudeLimit: ledger.currentLimit(at: now),
            codexLimits: codexLimits,
            claudeLimits: readClaudeLimits()?.current(at: now),
            usageHistory: ledgerReady ? ledger.history(days: 30, now: now) : [],
            codexTodayTokens: ledgerReady ? codexLedger.todayTokens(now: now) : nil,
            codexHistory: ledgerReady ? codexLedger.history(days: 30, now: now) : [])
    }

    // MARK: - Saved usage

    /// Where the ledgers keep what they've read, so a launch reads only what's new.
    private static let ledgerFolder = AgentMonitor.home.appendingPathComponent("Library/Application Support/LiveIsland", isDirectory: true)
    private static let claudeLedgerFile = ledgerFolder.appendingPathComponent("usage-ledger.json")
    private static let codexLedgerFile = ledgerFolder.appendingPathComponent("codex-usage.json")

    private func loadLedgers(now: Date) {
        if let saved = UsageLedger.load(from: Self.claudeLedgerFile) {
            ledger = saved
            // Replies that aged out while LiveIsland wasn't running go into the daily totals.
            ledger.prune(now: now)
        }
        if let saved = CodexUsageLedger.load(from: Self.codexLedgerFile) {
            codexLedger = saved
            codexLedger.prune(now: now)
        }
    }

    /// Saves at most once a minute, and only after something changed: when nothing is
    /// happening this costs nothing. A save that never happens (a crash) only means the next
    /// launch reads a little again: offsets and totals are always saved together.
    private func saveLedgersIfNeeded(now: Date) {
        guard ledgerReady, now.timeIntervalSince(lastLedgerSave) >= 60 else { return }
        lastLedgerSave = now
        codexLedger.prune(now: now)
        do {
            if ledger.hasUnsavedChanges { try ledger.save(to: Self.claudeLedgerFile) }
            if codexLedger.hasUnsavedChanges { try codexLedger.save(to: Self.codexLedgerFile) }
        } catch {
            log.error("Couldn't save token use: \(error.localizedDescription)")
        }
    }

    private var claudeLimitsFile: (modified: Date, limits: ClaudeUsageLimits?)?

    /// Re-reads the status line's file only when it changed.
    private func readClaudeLimits() -> ClaudeUsageLimits? {
        let url = AgentMonitor.claudeRoot.deletingLastPathComponent().appendingPathComponent(ClaudeUsageLimits.fileName)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            claudeLimitsFile = nil
            return nil
        }
        if let cached = claudeLimitsFile, cached.modified == modified { return cached.limits }
        let limits = (try? Data(contentsOf: url)).flatMap { ClaudeUsageLimits.parse($0, modified: modified) }
        claudeLimitsFile = (modified, limits)
        return limits
    }

    private func update(_ path: String, modified: Date) {
        if path.hasPrefix(AgentMonitor.claudeRoot.path) {
            // Subagent transcripts live beside their parent; the parent already shows the work.
            let name = URL(fileURLWithPath: path).lastPathComponent
            guard !path.contains("/subagents/"), !name.hasPrefix("agent-") else { return }
            let tail = ClaudeTranscript.tail(of: Self.lastLines(of: path))
            sessions[path] = Session(kind: .claude, modified: modified, claudeTail: tail)
        } else if path.hasPrefix(AgentMonitor.codexRoot.path) {
            readCodex(URL(fileURLWithPath: path), modified: modified)
        }
    }

    private func readCodex(_ url: URL, modified: Date) {
        codexLedger.ingest(url)
        let lines = Self.lastLines(of: url.path)
        let tail = CodexRollout.tail(of: lines)
        for line in lines.reversed() {
            if var limits = CodexRollout.limits(in: line) {
                limits.session = url.path
                if codexLimits == nil || limits.observedAt >= codexLimits!.observedAt { codexLimits = limits }
                break
            }
        }
        var session = sessions[url.path] ?? Session(kind: .codex, modified: modified)
        session.modified = modified
        session.codexTail = tail
        if session.codexCwd == nil { session.codexCwd = Self.firstLine(of: url.path).flatMap { CodexRollout.tail(of: [$0]).cwd } }
        sessions[url.path] = session
    }

    private static func lastLines(of path: String) -> [Data] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines: [Data] = []
        JSONLScanner.forEachLine(in: data) { lines.append($0) }
        // The first line may be cut in half.
        return start > 0 ? Array(lines.dropFirst()) : lines
    }

    private static func firstLine(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024), let end = data.firstIndex(of: 0x0A) else { return nil }
        return data[data.startIndex..<end]
    }

    private static func files(under root: URL, modifiedSince date: Date) -> [(url: URL, modified: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [(URL, Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified >= date
            else { continue }
            files.append((url, modified))
        }
        return files
    }

    /// "-Users-me-Code-app" → "app", when a transcript has no working directory yet.
    private static func claudeProjectFallback(_ path: String) -> String {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        return folder.split(separator: "-").last.map(String.init) ?? "Claude"
    }
}
