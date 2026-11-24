import Foundation

/// Counts Claude Code token use from transcripts, reading only what each file gained since
/// the last look. Transcripts can total gigabytes a day, so nothing is ever read twice (also
/// across launches: `save(to:)` keeps how far each file was read), and within new data only
/// the lines that matter are examined.
///
/// Recent replies are kept one by one, for the 5-hour window and today. Older ones are
/// rolled into daily totals per model and project (`history`), kept for `historyDays`.
/// Not thread-safe: use it from one queue.
public final class UsageLedger {
    /// How far back replies are kept one by one: enough for "today" and the current 5-hour window.
    public static let horizon: TimeInterval = 26 * 3600
    /// Claude's usage limits count in 5-hour windows starting at the first message.
    public static let windowLength: TimeInterval = 5 * 3600
    /// How many days of daily totals are kept.
    public static let historyDays = 90
    /// Replies older than `horizon` found while reading (a file not read for a while) still go
    /// into the daily totals, up to this age. Ids of rolled replies are remembered as long, so
    /// a reply copied into another transcript (a resumed session) isn't counted twice.
    public static let lateHorizon: TimeInterval = 8 * 86_400
    private static let chunkSize = 8 << 20
    /// The only lines that carry usage or limits.
    private static let markers = [ClaudeTranscript.assistantMarker, #""rate_limit_info""#]

    /// How far each file has been read, and which file it was (a replaced file starts over).
    private var offsets: [String: Position] = [:]
    /// Recent replies by message id.
    private var records: [String: Entry] = [:]
    private var history = UsageHistory()
    /// The start of the 5-hour window holding the newest pruned reply, so the chain of
    /// windows carries on from there instead of starting again at the oldest reply left.
    private var chainAnchor: Date?
    /// When Claude last answered: a limit notice older than that is stale.
    private var latestAnswer: Date?
    public private(set) var latestLimit: ClaudeLimitNotice?
    /// Bumped on every change, for the caches below and for saving.
    private var version = 0
    private var savedVersion = 0
    private var sortedCache: (version: Int, entries: [Entry])?
    private var windowCache: (version: Int, window: Window?)?
    private var todayCache: (version: Int, day: Date, summary: UsageSummary)?
    private var historyCache: (version: Int, key: String, days: [UsageDay])?

    public init() {}

    public var recordCount: Int { records.count }
    /// Whether anything changed since the last `save(to:)` (or the load).
    public var hasUnsavedChanges: Bool { version != savedVersion }

    /// The latest limit notice, unless Claude has answered since: then the limit was lifted
    /// (it reset early, or extra usage kicked in) and the notice is stale.
    public func currentLimit(at now: Date = Date()) -> ClaudeLimitNotice? {
        guard let notice = latestLimit, notice.isCurrent(at: now) else { return nil }
        if let answer = latestAnswer, answer > notice.observedAt { return nil }
        return notice
    }

    /// Reads the bytes appended to `url` since the last call. A file that was replaced,
    /// shrank or was rewritten in place is read again from the start.
    public func ingest(_ url: URL, now: Date = Date(), calendar: Calendar = .current) {
        ingest([url], now: now, concurrency: 1, calendar: calendar)
    }

    /// Reads many files, `concurrency` at a time, then merges the results.
    public func ingest(_ urls: [URL], now: Date = Date(), concurrency: Int, calendar: Calendar = .current) {
        let recent = now.addingTimeInterval(-Self.horizon)
        let late = now.addingTimeInterval(-Self.lateHorizon)
        let starts = urls.map { offsets[$0.path] }
        var results = [Scan?](repeating: nil, count: urls.count)
        let lanes = max(1, min(concurrency, urls.count))
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: lanes) { lane in
            for index in stride(from: lane, to: urls.count, by: lanes) {
                let scan = Self.scan(urls[index], from: starts[index], earliest: late)
                lock.lock()
                results[index] = scan
                lock.unlock()
            }
        }
        for (url, scan) in zip(urls, results) {
            guard let scan else { continue }
            if offsets[url.path] != scan.position {
                offsets[url.path] = scan.position
                version &+= 1
            }
            for record in scan.records {
                merge(record, recentSince: recent, calendar: calendar)
            }
            if let notice = scan.latestLimit, latestLimit == nil || notice.observedAt > latestLimit!.observedAt {
                latestLimit = notice
                version &+= 1
            }
        }
    }

    private func merge(_ record: ClaudeTranscript.UsageRecord, recentSince recent: Date, calendar: Calendar) {
        if latestAnswer == nil || record.timestamp > latestAnswer! {
            latestAnswer = record.timestamp
            version &+= 1
        }
        let id = record.messageID
        if var existing = records[id] {
            let counts = existing.counts.merged(with: record.counts)
            guard counts != existing.counts else { return }
            existing.counts = counts
            records[id] = existing
            version &+= 1
        } else if record.timestamp >= recent {
            records[id] = Entry(record)
            version &+= 1
        } else if history.add(Entry(record), id: id, day: UsageHistory.key(for: record.timestamp, calendar: calendar)) {
            version &+= 1
        }
    }

    /// Rolls replies too old to matter one by one into the daily totals, to keep memory flat.
    public func prune(now: Date = Date(), calendar: Calendar = .current) {
        let earliest = now.addingTimeInterval(-Self.horizon)
        let old = records.filter { $0.value.timestamp < earliest }
        if !old.isEmpty {
            let sorted = old.values.sorted { $0.timestamp < $1.timestamp }
            chainAnchor = Self.lastWindow(of: sorted, from: chainAnchor)?.start ?? chainAnchor
            for (id, entry) in old {
                history.add(entry, id: id, day: UsageHistory.key(for: entry.timestamp, calendar: calendar))
                records[id] = nil
            }
            version &+= 1
        }
        if history.trim(now: now, calendar: calendar) { version &+= 1 }
    }

    // MARK: - Summaries

    public func summary(now: Date = Date(), calendar: Calendar = .current) -> UsageSummary {
        let day = calendar.startOfDay(for: now)
        var summary: UsageSummary
        if let cached = todayCache, cached.version == version, cached.day == day {
            summary = cached.summary
        } else {
            summary = UsageSummary()
            // Records are sorted, so today's are the tail.
            let sorted = sortedEntries()
            var index = sorted.endIndex
            while index > sorted.startIndex, sorted[index - 1].timestamp >= day { index -= 1 }
            for entry in sorted[index...] {
                summary.today += entry.counts
                summary.todayCost.add(entry.counts, model: entry.model)
            }
            summary.todayRequests = sorted.endIndex - index
            summary.todayTokens = summary.today.fresh
            todayCache = (version, day, summary)
        }

        if let window = currentWindowChain(), now < window.start.addingTimeInterval(Self.windowLength), window.requests > 0 {
            summary.windowStart = window.start
            summary.windowEnd = window.start.addingTimeInterval(Self.windowLength)
            summary.window = window.counts
            summary.windowTokens = window.counts.fresh
            summary.windowRequests = window.requests
            summary.windowCost = window.cost
        }
        return summary
    }

    /// Daily totals for the last `days` days, oldest first and ending today, with a day for
    /// every date (empty if nothing was used). Days before LiveIsland first read the
    /// transcripts are empty: old transcripts are never read in full.
    public func history(days: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [UsageDay] {
        let today = calendar.startOfDay(for: now)
        let cacheKey = "\(UsageHistory.key(for: today, calendar: calendar))/\(days)/\(calendar.timeZone.identifier)"
        if let cached = historyCache, cached.version == version, cached.key == cacheKey { return cached.days }

        // Recent replies, not rolled yet, grouped the same way.
        var live: [String: [UsageBucket]] = [:]
        for entry in records.values {
            UsageHistory.add(entry, to: &live[UsageHistory.key(for: entry.timestamp, calendar: calendar), default: []])
        }
        var result: [UsageDay] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = UsageHistory.key(for: start, calendar: calendar)
            var buckets = history.days[key] ?? []
            for bucket in live[key] ?? [] { UsageHistory.add(bucket, to: &buckets) }
            result.append(UsageDay(start: start, buckets: buckets))
        }
        historyCache = (version, cacheKey, result)
        return result
    }

    private func sortedEntries() -> [Entry] {
        if let cached = sortedCache, cached.version == version { return cached.entries }
        let sorted = records.values.sorted { $0.timestamp < $1.timestamp }
        sortedCache = (version, sorted)
        return sorted
    }

    private func currentWindowChain() -> Window? {
        if let cached = windowCache, cached.version == version { return cached.window }
        let window = Self.lastWindow(of: sortedEntries(), from: chainAnchor)
        windowCache = (version, window)
        return window
    }

    private struct Window {
        var start: Date
        var counts = TokenCounts()
        var requests = 0
        var cost = CostEstimate()
    }

    /// Rebuilds the 5-hour windows: each starts on the hour of the first message after the
    /// previous one ended, carrying on from `anchor` (the window of the newest pruned reply).
    /// Hours are UTC hours: the limits' hours, also where the time zone is 30 or 45 minutes
    /// off the hour (India, Nepal, Adelaide) or the clocks just changed.
    private static func lastWindow(of sorted: [Entry], from anchor: Date?) -> Window? {
        var window = anchor.map { Window(start: $0) }
        for entry in sorted {
            if let start = window?.start, entry.timestamp < start.addingTimeInterval(windowLength) {
                // A reply from before the anchor's window belongs to one already over.
                guard entry.timestamp >= start else { continue }
            } else {
                window = Window(start: hourStart(of: entry.timestamp))
            }
            window!.counts += entry.counts
            window!.requests += 1
            window!.cost.add(entry.counts, model: entry.model)
        }
        return window
    }

    static func hourStart(of date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    // MARK: - Saving

    /// Writes everything (offsets, recent replies, daily totals) to `url`, atomically and
    /// readable only by the user, so the next launch reads only what's new.
    public func save(to url: URL) throws {
        let stored = Stored(
            format: Stored.currentFormat, offsets: offsets, records: records, history: history,
            chainAnchor: chainAnchor, latestAnswer: latestAnswer, latestLimit: latestLimit.map(StoredNotice.init))
        try LedgerFile.write(LedgerFile.encoder.encode(stored), to: url)
        savedVersion = version
    }

    /// The ledger saved at `url`, or nil when there's none or it can't be read; a damaged
    /// file is set aside (`.bad`) so the next save starts clean. Nothing is lost for good:
    /// the transcripts are still there to read again.
    public static func load(from url: URL) -> UsageLedger? {
        guard let data = LedgerFile.read(url) else { return nil }
        guard let ledger = UsageLedger(restoring: data) else {
            LedgerFile.setAside(url)
            return nil
        }
        return ledger
    }

    /// A ledger from `save(to:)`'s data, or nil if it's damaged or from another format.
    public convenience init?(restoring data: Data) {
        guard let stored = try? LedgerFile.decoder.decode(Stored.self, from: data), stored.format == Stored.currentFormat
        else { return nil }
        self.init()
        offsets = stored.offsets
        records = stored.records
        history = stored.history
        chainAnchor = stored.chainAnchor
        latestAnswer = stored.latestAnswer
        latestLimit = stored.latestLimit?.notice
    }

    private struct Stored: Codable {
        static let currentFormat = 1
        var format: Int
        var offsets: [String: Position]
        var records: [String: Entry]
        var history: UsageHistory
        var chainAnchor: Date?
        var latestAnswer: Date?
        var latestLimit: StoredNotice?
    }

    private struct StoredNotice: Codable {
        var status: String, type: String, resetsAt: Date, observedAt: Date, session: String?

        init(_ notice: ClaudeLimitNotice) {
            (status, type, resetsAt, observedAt, session) = (notice.status, notice.type, notice.resetsAt, notice.observedAt, notice.session)
        }

        var notice: ClaudeLimitNotice {
            ClaudeLimitNotice(status: status, type: type, resetsAt: resetsAt, observedAt: observedAt, session: session)
        }
    }

    // MARK: - Scanning

    /// One recent reply.
    struct Entry: Codable, Equatable {
        var timestamp: Date
        var model: String?
        var project: String?
        var counts: TokenCounts

        init(_ record: ClaudeTranscript.UsageRecord) {
            (timestamp, model, project, counts) = (record.timestamp, record.model, record.project, record.counts)
        }

        private enum CodingKeys: String, CodingKey { case timestamp = "t", model = "m", project = "p", counts = "c" }
    }

    private struct Position: Codable, Equatable {
        var inode: UInt64
        var offset: UInt64
        /// The newest timestamp read so far, for a limit notice logged without one.
        var stamp: Date?
    }

    private struct Scan {
        var position: Position
        var records: [ClaudeTranscript.UsageRecord] = []
        var latestLimit: ClaudeLimitNotice?
    }

    /// Reads one file from where the last scan stopped. Safe to run on any thread.
    private static func scan(_ url: URL, from previous: Position?, earliest: Date) -> Scan? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The open file's own identity and size: a path lookup could see a different file.
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        let inode = UInt64(info.st_ino), size = UInt64(max(0, info.st_size))
        var offset = previous.map { $0.inode == inode ? $0.offset : 0 } ?? 0
        if size < offset { offset = 0 }
        // Reading always stops after a newline, so anything else there means the file was
        // rewritten in place (same inode, at least as long): start over.
        if offset > 0, (try? handle.seek(toOffset: offset - 1)) == nil || (try? handle.read(upToCount: 1)) != Data([0x0A]) {
            offset = 0
        }
        var scan = Scan(position: Position(inode: inode, offset: offset, stamp: offset > 0 ? previous?.stamp : nil))
        guard size > offset else { return scan }

        var pending = Data()
        // A response is written once per content block, with counts that can grow line to
        // line: keep the largest per id. Only a line that parsed counts as seen.
        var byID: [String: Int] = [:]
        var stamp = scan.position.stamp
        do {
            try handle.seek(toOffset: offset)
            while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: chunkSize) }), !chunk.isEmpty {
                pending.append(chunk)
                let consumed = autoreleasepool { JSONLScanner.forEachLine(containing: markers, in: pending) { line, hits in
                    if hits[1] != nil, let found = ClaudeTranscript.limitNotice(in: line, undatedObservedAt: stamp) {
                        if scan.latestLimit == nil || found.observedAt > scan.latestLimit!.observedAt {
                            var notice = found
                            notice.session = url.path
                            scan.latestLimit = notice
                        }
                        return
                    }
                    guard let hit = hits[0], let record = ClaudeTranscript.usageRecord(in: line, assistantAt: hit) else { return }
                    stamp = max(stamp ?? record.timestamp, record.timestamp)
                    guard record.timestamp >= earliest else { return }
                    if let index = byID[record.messageID] {
                        let first = scan.records[index]
                        scan.records[index] = ClaudeTranscript.UsageRecord(
                            messageID: first.messageID, timestamp: first.timestamp, counts: first.counts.merged(with: record.counts),
                            model: first.model ?? record.model, project: first.project ?? record.project)
                    } else {
                        byID[record.messageID] = scan.records.count
                        scan.records.append(record)
                    }
                } }
                offset += UInt64(consumed)
                pending.removeSubrange(pending.startIndex..<pending.startIndex + consumed)
            }
        } catch {
            return nil
        }
        scan.position.offset = offset
        scan.position.stamp = stamp
        return scan
    }
}

/// One group of replies in a day: one model in one project.
public struct UsageBucket: Codable, Equatable, Hashable, Sendable {
    public var model: String?
    public var project: String?
    public var counts: TokenCounts
    public var requests: Int
    public var cost: CostEstimate

    public init(model: String?, project: String?, counts: TokenCounts = TokenCounts(), requests: Int = 0, cost: CostEstimate = CostEstimate()) {
        self.model = model
        self.project = project
        self.counts = counts
        self.requests = requests
        self.cost = cost
    }

    private enum CodingKeys: String, CodingKey { case model = "m", project = "p", counts = "c", requests = "n", cost = "$" }
}

/// One day's Claude Code use, in total and per model and project.
public struct UsageDay: Equatable, Sendable {
    /// Midnight, local time.
    public var start: Date
    /// Biggest first (by estimated cost, then tokens).
    public var buckets: [UsageBucket]
    public var counts: TokenCounts
    public var requests: Int
    public var cost: CostEstimate

    public init(start: Date, buckets: [UsageBucket]) {
        self.start = start
        self.buckets = buckets.sorted {
            $0.cost.dollars != $1.cost.dollars ? $0.cost.dollars > $1.cost.dollars : $0.counts.fresh > $1.counts.fresh
        }
        counts = buckets.reduce(TokenCounts()) { $0 + $1.counts }
        requests = buckets.reduce(0) { $0 + $1.requests }
        cost = buckets.reduce(into: CostEstimate()) { $0 += $1.cost }
    }

    /// Totals per model, biggest first.
    public var byModel: [UsageBucket] { Self.grouped(buckets) { UsageBucket(model: $0.model, project: nil) } }
    /// Totals per project, biggest first.
    public var byProject: [UsageBucket] { Self.grouped(buckets) { UsageBucket(model: nil, project: $0.project) } }

    private static func grouped(_ buckets: [UsageBucket], by key: (UsageBucket) -> UsageBucket) -> [UsageBucket] {
        var groups: [UsageBucket] = []
        for bucket in buckets {
            var group = key(bucket)
            group.counts = bucket.counts
            group.requests = bucket.requests
            group.cost = bucket.cost
            UsageHistory.add(group, to: &groups)
        }
        return UsageDay(start: .distantPast, buckets: groups).buckets
    }
}

/// Daily totals of replies rolled out of the ledger, and the ids already rolled.
struct UsageHistory: Codable, Equatable {
    /// Buckets by day ("2026-10-22", local calendar).
    var days: [String: [UsageBucket]] = [:]
    /// Hashes of the ids rolled each day, kept for `UsageLedger.lateHorizon`.
    var rolled: [String: Set<UInt64>] = [:]

    /// Adds a reply to its day, unless it was rolled already. Returns whether it was added.
    @discardableResult
    mutating func add(_ entry: UsageLedger.Entry, id: String, day: String) -> Bool {
        let hash = Self.hash(id)
        guard rolled[day, default: []].insert(hash).inserted else { return false }
        var cost = CostEstimate()
        cost.add(entry.counts, model: entry.model)
        Self.add(UsageBucket(model: entry.model, project: entry.project, counts: entry.counts, requests: 1, cost: cost),
                 to: &days[day, default: []])
        return true
    }

    static func add(_ entry: UsageLedger.Entry, to buckets: inout [UsageBucket]) {
        var cost = CostEstimate()
        cost.add(entry.counts, model: entry.model)
        add(UsageBucket(model: entry.model, project: entry.project, counts: entry.counts, requests: 1, cost: cost), to: &buckets)
    }

    static func add(_ bucket: UsageBucket, to buckets: inout [UsageBucket]) {
        if let index = buckets.firstIndex(where: { $0.model == bucket.model && $0.project == bucket.project }) {
            buckets[index].counts += bucket.counts
            buckets[index].requests += bucket.requests
            buckets[index].cost += bucket.cost
        } else {
            buckets.append(bucket)
        }
    }

    /// Drops days past `UsageLedger.historyDays` and ids past `lateHorizon`. Returns whether
    /// anything went.
    mutating func trim(now: Date, calendar: Calendar) -> Bool {
        let dayCutoff = calendar.date(byAdding: .day, value: -UsageLedger.historyDays, to: calendar.startOfDay(for: now)) ?? now
        let idCutoff = calendar.startOfDay(for: now.addingTimeInterval(-UsageLedger.lateHorizon - 86_400))
        let oldestDay = Self.key(for: dayCutoff, calendar: calendar), oldestIDs = Self.key(for: idCutoff, calendar: calendar)
        let before = (days.count, rolled.count)
        // Keys sort as dates.
        days = days.filter { $0.key >= oldestDay }
        rolled = rolled.filter { $0.key >= oldestIDs }
        return before != (days.count, rolled.count)
    }

    static func key(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// FNV-1a: stable across launches, unlike `Hasher`.
    static func hash(_ id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    // Id hashes are packed into one base64 blob per day: a JSON list of numbers would be
    // several times larger and could lose precision above 2^53.
    private enum CodingKeys: String, CodingKey { case days, rolled }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        days = try container.decode([String: [UsageBucket]].self, forKey: .days)
        let packed = try container.decode([String: Data].self, forKey: .rolled)
        rolled = packed.mapValues { data in
            var set = Set<UInt64>()
            data.withUnsafeBytes { raw in
                for index in 0..<raw.count / 8 { set.insert(UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))) }
            }
            return set
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days, forKey: .days)
        let packed = rolled.mapValues { set in
            var data = Data(capacity: set.count * 8)
            for hash in set.sorted() { withUnsafeBytes(of: hash.littleEndian) { data.append(contentsOf: $0) } }
            return data
        }
        try container.encode(packed, forKey: .rolled)
    }
}

/// Reading and writing the ledgers' small JSON files.
enum LedgerFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    static func read(_ url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Moves a file that couldn't be read out of the way, replacing an older one set aside.
    static func setAside(_ url: URL) {
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: url, to: bad)
    }
}
