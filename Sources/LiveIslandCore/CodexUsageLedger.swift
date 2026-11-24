import Foundation

/// Counts Codex token use per day from its rollouts. Codex logs a running total per session
/// (`total_token_usage.total_tokens`), so each new total adds what grew since the last one,
/// on the day it was logged. Like `UsageLedger`, it reads only what each file gained, and
/// `save(to:)` keeps that across launches. Not thread-safe: use it from one queue.
public final class CodexUsageLedger {
    private static let chunkSize = 8 << 20
    private static let markers = [#""total_token_usage""#]
    /// Files untouched this long are forgotten (rollouts live in dated folders and stop growing).
    private static let fileMemory: TimeInterval = 30 * 86_400

    private var files: [String: FileState] = [:]
    /// Tokens by day ("2026-10-22", local calendar).
    private var days: [String: Int] = [:]
    private var version = 0
    private var savedVersion = 0

    public init() {}

    public var hasUnsavedChanges: Bool { version != savedVersion }

    public func todayTokens(now: Date = Date(), calendar: Calendar = .current) -> Int {
        days[UsageHistory.key(for: now, calendar: calendar)] ?? 0
    }

    /// Tokens per day for the last `days` days, oldest first and ending today.
    public func history(days count: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [CodexUsageDay] {
        let today = calendar.startOfDay(for: now)
        let key = "\(today.timeIntervalSince1970)/\(count)/\(calendar.timeZone.identifier)"
        if let cached = historyCache, cached.version == version, cached.key == key { return cached.days }
        let result: [CodexUsageDay] = stride(from: count - 1, through: 0, by: -1).compactMap { offset in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return CodexUsageDay(start: start, tokens: days[UsageHistory.key(for: start, calendar: calendar)] ?? 0)
        }
        historyCache = (version, key, result)
        return result
    }

    /// The island asks every few seconds; the answer changes only with new totals or a new day.
    private var historyCache: (version: Int, key: String, days: [CodexUsageDay])?

    public func ingest(_ url: URL, now: Date = Date(), calendar: Calendar = .current) {
        ingest([url], now: now, calendar: calendar)
    }

    public func ingest(_ urls: [URL], now: Date = Date(), calendar: Calendar = .current) {
        for url in urls {
            let previous = files[url.path]
            guard var state = Self.scan(url, from: previous, calendar: calendar, into: &days, changed: &version) else { continue }
            let moved = previous.map { ($0.inode, $0.offset, $0.total) != (state.inode, state.offset, state.total) } ?? true
            state.seen = now
            files[url.path] = state
            // Only reading counts as a change worth saving, not the look itself.
            if moved { version &+= 1 }
        }
    }

    /// Forgets old days and files.
    public func prune(now: Date = Date(), calendar: Calendar = .current) {
        let cutoff = calendar.date(byAdding: .day, value: -UsageLedger.historyDays, to: calendar.startOfDay(for: now)) ?? now
        let oldest = UsageHistory.key(for: cutoff, calendar: calendar)
        let before = (days.count, files.count)
        days = days.filter { $0.key >= oldest }
        files = files.filter { now.timeIntervalSince($0.value.seen) < Self.fileMemory }
        if before != (days.count, files.count) { version &+= 1 }
    }

    private struct FileState: Codable, Equatable {
        var inode: UInt64
        var offset: UInt64
        /// The largest running total seen: only growth beyond it counts, so a file read
        /// again (rewritten, or replaced by a copy) adds nothing twice.
        var total: Int
        var seen: Date
    }

    private static func scan(_ url: URL, from previous: FileState?, calendar: Calendar,
                             into days: inout [String: Int], changed version: inout Int) -> FileState? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let inode = UInt64(info.st_ino), size = UInt64(max(0, info.st_size))
        var offset = previous.map { $0.inode == inode ? $0.offset : 0 } ?? 0
        if size < offset { offset = 0 }
        if offset > 0, (try? handle.seek(toOffset: offset - 1)) == nil || (try? handle.read(upToCount: 1)) != Data([0x0A]) {
            offset = 0
        }
        var state = FileState(inode: inode, offset: offset, total: previous?.total ?? 0, seen: previous?.seen ?? .distantPast)
        guard size > offset else { return state }

        var pending = Data()
        var added: [String: Int] = [:]
        do {
            try handle.seek(toOffset: offset)
            while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty {
                pending.append(chunk)
                let consumed = JSONLScanner.forEachLine(containing: markers, in: pending) { line, _ in
                    guard let total = CodexRollout.totalTokens(in: line) else { return }
                    defer { state.total = max(state.total, total) }
                    guard total > state.total,
                          // Codex writes the timestamp first.
                          let stamp = JSONLScanner.string(after: #""timestamp":""#, in: line).flatMap(Format.date(iso8601:))
                    else { return }
                    added[UsageHistory.key(for: stamp, calendar: calendar), default: 0] += total - state.total
                }
                offset += UInt64(consumed)
                pending.removeSubrange(pending.startIndex..<pending.startIndex + consumed)
            }
        } catch {
            return nil
        }
        for (day, tokens) in added { days[day, default: 0] += tokens }
        if !added.isEmpty { version &+= 1 }
        state.offset = offset
        return state
    }

    // MARK: - Saving

    public func save(to url: URL) throws {
        try LedgerFile.write(LedgerFile.encoder.encode(Stored(format: Stored.currentFormat, files: files, days: days)), to: url)
        savedVersion = version
    }

    /// The ledger saved at `url`, or nil when there's none or it can't be read (a damaged
    /// file is set aside).
    public static func load(from url: URL) -> CodexUsageLedger? {
        guard let data = LedgerFile.read(url) else { return nil }
        guard let ledger = CodexUsageLedger(restoring: data) else {
            LedgerFile.setAside(url)
            return nil
        }
        return ledger
    }

    public convenience init?(restoring data: Data) {
        guard let stored = try? LedgerFile.decoder.decode(Stored.self, from: data), stored.format == Stored.currentFormat
        else { return nil }
        self.init()
        files = stored.files
        days = stored.days
    }

    private struct Stored: Codable {
        static let currentFormat = 1
        var format: Int
        var files: [String: FileState]
        var days: [String: Int]
    }
}

/// One day of Codex use.
public struct CodexUsageDay: Equatable, Sendable {
    /// Midnight, local time.
    public var start: Date
    public var tokens: Int

    public init(start: Date, tokens: Int) {
        self.start = start
        self.tokens = tokens
    }
}
