import Foundation
import Testing
@testable import LiveIslandCore

/// A scratch transcript and the helpers to write it like Claude Code and Codex do.
private struct Scratch {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }

    func file(_ name: String = "session.jsonl") -> URL { folder.appendingPathComponent(name) }

    func append(_ lines: [String], to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        try handle.close()
    }

    func remove() { try? FileManager.default.removeItem(at: folder) }
}

private func date(_ text: String) -> Date { Format.date(iso8601: text)! }

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let utc = calendar("UTC")

/// A reply that used only fresh input, for easy sums.
private func reply(_ id: String, at time: String, input: Int = 1, model: String = "claude-opus-5-5", cwd: String = "/Users/me/Code/app") -> String {
    Fixture.claudeAssistant(id: id, at: time, input: input, output: 0, cacheWrite: 0, cacheRead: 0)
        .replacingOccurrences(of: #""model":"claude-opus-5-5""#, with: #""model":"\#(model)""#)
        .replacingOccurrences(of: #""cwd":"/Users/me/Code/app""#, with: #""cwd":"\#(cwd)""#)
}

@Suite("Usage windows")
struct UsageWindowTests {
    @Test(arguments: ["UTC", "Asia/Kolkata", "Asia/Kathmandu", "Australia/Adelaide", "America/New_York"])
    func windowsStartOnTheUTCHourInEveryTimeZone(zone: String) throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        try scratch.append([reply("msg_1", at: "2026-10-22T09:42:00.000Z")], to: url)
        let now = date("2026-10-22T10:00:00.000Z")
        let ledger = UsageLedger()
        ledger.ingest(url, now: now, calendar: calendar(zone))
        let summary = ledger.summary(now: now, calendar: calendar(zone))
        // India is +5:30 and Nepal +5:45: a local hour would start at 09:30 or 09:15 UTC.
        #expect(summary.windowStart == date("2026-10-22T09:00:00.000Z"))
        #expect(summary.windowEnd == date("2026-10-22T14:00:00.000Z"))
    }

    @Test func aClockChangeDoesNotMoveTheWindow() throws {
        // New York falls back on 2026-11-01 at 06:00 UTC (2:00 EDT becomes 1:00 EST).
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        try scratch.append([reply("msg_1", at: "2026-11-01T05:30:00.000Z"), reply("msg_2", at: "2026-11-01T06:30:00.000Z")], to: url)
        let now = date("2026-11-01T07:00:00.000Z")
        let ledger = UsageLedger()
        let newYork = calendar("America/New_York")
        ledger.ingest(url, now: now, calendar: newYork)
        let summary = ledger.summary(now: now, calendar: newYork)
        #expect(summary.windowStart == date("2026-11-01T05:00:00.000Z"))
        #expect(summary.windowEnd == date("2026-11-01T10:00:00.000Z"), "five real hours, not four or six")
        #expect(summary.windowRequests == 2)
    }

    @Test func theWindowKeepsItsAnchorAfterOldRepliesArePruned() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        // One window from 00:00 holds 00:10, 03:00 and 04:30; 05:30 starts the next at 05:00.
        try scratch.append([
            reply("msg_a", at: "2026-10-20T00:10:00.000Z"), reply("msg_b", at: "2026-10-20T03:00:00.000Z"),
            reply("msg_c", at: "2026-10-20T04:30:00.000Z"), reply("msg_d", at: "2026-10-20T05:30:00.000Z"),
        ], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: date("2026-10-20T06:00:00.000Z"), calendar: utc)
        // A day later only 00:10 is past the horizon. Starting again from 03:00 would make
        // 03:00–08:00 a window and put 05:30 in it.
        ledger.prune(now: date("2026-10-21T04:00:00.000Z"), calendar: utc)
        #expect(ledger.recordCount == 3)
        let summary = ledger.summary(now: date("2026-10-20T06:00:00.000Z"), calendar: utc)
        #expect(summary.windowStart == date("2026-10-20T05:00:00.000Z"))
        #expect(summary.windowRequests == 1)

        // The anchor is saved with the rest.
        let saved = scratch.file("ledger.json")
        try ledger.save(to: saved)
        let restored = try #require(UsageLedger.load(from: saved))
        #expect(restored.summary(now: date("2026-10-20T06:00:00.000Z"), calendar: utc).windowStart == date("2026-10-20T05:00:00.000Z"))
    }
}

@Suite("Usage ledger reading")
struct UsageLedgerReadingTests {
    @Test func aFirstBlockLineWithoutUsageDoesNotHideTheReply() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let full = Fixture.claudeAssistant(id: "msg_A", at: "2026-10-22T11:00:00.000Z")
        let noUsage = full.replacingOccurrences(of: #""usage":{"#, with: #""usage_pending":{"#)
        try scratch.append([noUsage, full], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: date("2026-10-22T12:00:00.000Z"))
        #expect(ledger.recordCount == 1)
    }

    @Test func aLineLongerThanAReadIsStillCounted() throws {
        // Reads come 8 MB at a time; a reply with a huge pasted file spans several of them.
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let huge = String(repeating: "x", count: 9 << 20)
        let big = Fixture.claudeAssistant(id: "msg_big", at: "2026-10-22T11:00:00.000Z", input: 7, output: 0, cacheWrite: 0, cacheRead: 0,
                                          content: #"[{"type":"text","text":"\#(huge)"}]"#)
        try scratch.append([reply("msg_small", at: "2026-10-22T10:59:00.000Z", input: 3), big,
                            reply("msg_after", at: "2026-10-22T11:01:00.000Z", input: 5)], to: url)
        let now = date("2026-10-22T12:00:00.000Z")
        let ledger = UsageLedger()
        ledger.ingest(url, now: now, calendar: utc)
        #expect(ledger.recordCount == 3)
        #expect(ledger.summary(now: now, calendar: utc).today.input == 15)
        // Everything was read: reading again adds nothing.
        ledger.ingest(url, now: now, calendar: utc)
        #expect(ledger.summary(now: now, calendar: utc).today.input == 15)
    }

    @Test func aRecentReplyInTwoTranscriptsCountsOnce() throws {
        // A resumed or forked session copies the conversation, recent replies included.
        let scratch = Scratch()
        defer { scratch.remove() }
        let now = date("2026-10-22T12:00:00.000Z")
        let shared = reply("msg_shared", at: "2026-10-22T11:00:00.000Z", input: 40)
        try scratch.append([shared], to: scratch.file("first.jsonl"))
        try scratch.append([shared, reply("msg_own", at: "2026-10-22T11:30:00.000Z", input: 2)], to: scratch.file("fork.jsonl"))
        let ledger = UsageLedger()
        ledger.ingest([scratch.file("first.jsonl"), scratch.file("fork.jsonl")], now: now, concurrency: 2, calendar: utc)
        let summary = ledger.summary(now: now, calendar: utc)
        #expect(ledger.recordCount == 2)
        #expect(summary.today.input == 42)
        #expect(summary.todayRequests == 2)
    }

    @Test func theLargestUsageOfAReplysLinesCounts() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let now = date("2026-10-22T12:00:00.000Z")
        // Output streams in: the first block's line has fewer output tokens than the last.
        try scratch.append([Fixture.claudeAssistant(id: "msg_A", at: "2026-10-22T11:00:00.000Z", output: 5)], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: now, calendar: utc)
        try scratch.append([Fixture.claudeAssistant(id: "msg_A", at: "2026-10-22T11:00:02.000Z", output: 200)], to: url)
        ledger.ingest(url, now: now, calendar: utc)
        let summary = ledger.summary(now: now, calendar: utc)
        #expect(ledger.recordCount == 1)
        #expect(summary.today.output == 200)
        #expect(summary.todayRequests == 1)
    }

    @Test func keepsEachKindOfTokenApart() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        try scratch.append([Fixture.claudeAssistant(id: "msg_A", at: "2026-10-22T11:00:00.000Z")], to: url)
        let now = date("2026-10-22T12:00:00.000Z")
        let ledger = UsageLedger()
        ledger.ingest(url, now: now, calendar: utc)
        let summary = ledger.summary(now: now, calendar: utc)
        #expect(summary.today == TokenCounts(input: 10, output: 200, cacheWrite: 300, cacheWrite1h: 300, cacheRead: 4_000))
        #expect(summary.todayTokens == 510, "cache reads aren't in the headline number")
        #expect(summary.window == summary.today)
    }

    @Test func repliesFromProxiesCountToo() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let proxy = Fixture.claudeAssistant(id: "chatcmpl-9f2", at: "2026-10-22T11:00:00.000Z")
        // No message id at all: the request id ties the lines together.
        let noID = Fixture.claudeAssistant(id: "", at: "2026-10-22T11:10:00.000Z").replacingOccurrences(of: #""id":"","#, with: "")
            .replacingOccurrences(of: "req_1", with: "req_77")
        try scratch.append([proxy, proxy, noID, noID], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: date("2026-10-22T12:00:00.000Z"))
        #expect(ledger.recordCount == 2)
    }

    @Test func aToolCallsIdIsNotTheReplysId() throws {
        let content = #"[{"type":"tool_use","id":"toolu_9","name":"Read","input":{}}]"#
        let line = Fixture.claudeAssistant(id: "x", content: content).replacingOccurrences(of: #""id":"x","#, with: "")
        let record = try #require(ClaudeTranscript.usageRecord(in: Fixture.data(line)))
        #expect(record.messageID == "req:req_1")
    }

    @Test func apiErrorsAreNotReplies() {
        let line = Fixture.claudeAssistant(id: "6a1f", at: "2026-10-22T11:00:00.000Z")
            .replacingOccurrences(of: #""timestamp":"#, with: #""isApiErrorMessage":true,"timestamp":"#)
        #expect(ClaudeTranscript.usageRecord(in: Fixture.data(line)) == nil)
        let synthetic = Fixture.claudeAssistant(id: "6a2f").replacingOccurrences(of: "claude-opus-5-5", with: "<synthetic>")
        #expect(ClaudeTranscript.usageRecord(in: Fixture.data(synthetic)) == nil)
    }

    @Test func recordsKnowTheirModelAndProject() throws {
        let record = try #require(ClaudeTranscript.usageRecord(in: Fixture.data(reply("msg_1", at: "2026-10-22T11:00:00.000Z", cwd: "/Users/me/Code/live-island"))))
        #expect(record.model == "claude-opus-5-5")
        #expect(record.project == "live-island")
        #expect(record.counts.input == 1)
    }

    @Test func theScannersHitGivesTheSameRecordAsAFullSearch() throws {
        let line = Fixture.data(Fixture.claudeAssistant())
        let hit = try #require(JSONLScanner.range(of: Array(#""type":"assistant""#.utf8), in: line, last: false)).lowerBound
        #expect(ClaudeTranscript.usageRecord(in: line, assistantAt: hit) == ClaudeTranscript.usageRecord(in: line))
    }

    @Test func aFileRewrittenInPlaceIsReadAgain() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let now = date("2026-10-22T12:00:00.000Z")
        try scratch.append([Fixture.claudeAssistant(id: "msg_P", at: "2026-10-22T11:00:00.000Z")], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: now)
        // Same file (same inode), new and longer content: the old offset lands mid-line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((Fixture.claudeAssistant(id: "msg_Rewritten_with_a_longer_id", at: "2026-10-22T11:20:00.000Z",
                                                                    content: #"[{"type":"text","text":"a longer reply"}]"#) + "\n").utf8))
        try handle.close()
        ledger.ingest(url, now: now)
        #expect(ledger.recordCount == 2)
    }

    @Test func anUndatedLimitNoticeTakesTheTimeOfTheReplyBeforeIt() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let undated = Fixture.claudeLimit.replacingOccurrences(of: #","timestamp":"2026-10-20T08:00:00.000Z""#, with: "")
        try scratch.append([reply("msg_1", at: "2026-10-20T07:59:00.000Z"), undated], to: url)
        let ledger = UsageLedger()
        let now = date("2026-10-20T09:00:00.000Z")
        ledger.ingest(url, now: now)
        #expect(ledger.latestLimit?.observedAt == date("2026-10-20T07:59:00.000Z"))
        #expect(ledger.currentLimit(at: now) != nil)
        try scratch.append([reply("msg_2", at: "2026-10-20T08:30:00.000Z")], to: url)
        ledger.ingest(url, now: now)
        #expect(ledger.currentLimit(at: now) == nil, "a reply after it lifts it, as for a dated one")
    }

    @Test func anUndatedLimitNoticeWithNothingBeforeItIsDropped() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        try scratch.append([Fixture.claudeLimit.replacingOccurrences(of: #","timestamp":"2026-10-20T08:00:00.000Z""#, with: "")], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: date("2026-10-20T09:00:00.000Z"))
        #expect(ledger.latestLimit == nil, "with a made-up time it would never go away")
    }
}

@Suite("Usage ledger saving")
struct UsageLedgerSavingTests {
    @Test func aRestoredLedgerReadsOnlyWhatsNew() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        let saved = scratch.file("ledger.json")
        let now = date("2026-10-22T12:00:00.000Z")
        try scratch.append([reply("msg_1", at: "2026-10-22T11:00:00.000Z"), reply("msg_2", at: "2026-10-22T11:01:00.000Z")], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: now, calendar: utc)
        #expect(ledger.hasUnsavedChanges)
        try ledger.save(to: saved)
        #expect(!ledger.hasUnsavedChanges)
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let restored = try #require(UsageLedger.load(from: saved))
        #expect(restored.recordCount == 2)
        restored.ingest(url, now: now, calendar: utc)
        #expect(!restored.hasUnsavedChanges, "nothing new, nothing read")
        try scratch.append([reply("msg_3", at: "2026-10-22T11:02:00.000Z", input: 5)], to: url)
        restored.ingest(url, now: now, calendar: utc)
        let summary = restored.summary(now: now, calendar: utc)
        #expect(summary.todayRequests == 3)
        #expect(summary.todayTokens == 1 + 1 + 5)
    }

    @Test func aDamagedFileIsSetAside() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let saved = scratch.file("ledger.json")
        try Data(#"{"format":1,"offsets":{"#.utf8).write(to: saved)
        #expect(UsageLedger.load(from: saved) == nil)
        #expect(FileManager.default.fileExists(atPath: saved.path + ".bad"))
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        #expect(UsageLedger(restoring: Data(#"{"format":99}"#.utf8)) == nil, "another format starts over")
        #expect(UsageLedger.load(from: scratch.file("missing.json")) == nil)
    }
}

@Suite("Usage history")
struct UsageHistoryTests {
    @Test func prunedRepliesRollIntoDailyTotalsPerModelAndProject() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        try scratch.append([
            reply("msg_1", at: "2026-10-20T10:00:00.000Z", input: 100, model: "claude-opus-5-5", cwd: "/Users/me/Code/app"),
            reply("msg_2", at: "2026-10-20T11:00:00.000Z", input: 200, model: "claude-sonnet-5-5", cwd: "/Users/me/Code/app"),
            reply("msg_3", at: "2026-10-20T12:00:00.000Z", input: 300, model: "claude-opus-5-5", cwd: "/Users/me/Code/api"),
            reply("msg_4", at: "2026-10-22T09:00:00.000Z", input: 7),
        ], to: url)
        let ledger = UsageLedger()
        ledger.ingest(url, now: date("2026-10-20T13:00:00.000Z"), calendar: utc)
        let now = date("2026-10-22T10:00:00.000Z")
        ledger.ingest(url, now: now, calendar: utc)
        ledger.prune(now: now, calendar: utc)
        #expect(ledger.recordCount == 1, "only today's reply is still kept one by one")

        let days = ledger.history(days: 3, now: now, calendar: utc)
        #expect(days.map(\.start) == [date("2026-10-20T00:00:00.000Z"), date("2026-10-21T00:00:00.000Z"), date("2026-10-22T00:00:00.000Z")])
        let first = days[0]
        #expect(first.requests == 3)
        #expect(first.counts.input == 600)
        #expect(first.buckets.count == 3)
        #expect(first.byModel.map(\.model) == ["claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(first.byModel.first?.counts.input == 400)
        #expect(first.byProject.first { $0.project == "api" }?.requests == 1)
        #expect(days[1].requests == 0, "a quiet day is there, empty")
        #expect(days[2].requests == 1, "today comes from the replies not rolled yet")
        // Opus 5.5 at $4 and Sonnet 5.5 at $2 per million input tokens.
        #expect(abs(first.cost.dollars - (400 * 4 + 200 * 2) / 1_000_000) < 1e-12)

        // History survives a save.
        let saved = scratch.file("ledger.json")
        try ledger.save(to: saved)
        #expect(try #require(UsageLedger.load(from: saved)).history(days: 3, now: now, calendar: utc) == days)
    }

    @Test func aReplyCopiedIntoAnotherTranscriptIsntCountedTwice() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let old = reply("msg_old", at: "2026-10-18T10:00:00.000Z", input: 50)
        try scratch.append([old], to: scratch.file("first.jsonl"))
        let ledger = UsageLedger()
        let now = date("2026-10-22T10:00:00.000Z")
        // Both are read only now, days later: the reply goes straight to its day.
        ledger.ingest(scratch.file("first.jsonl"), now: now, calendar: utc)
        // A resumed session starts a new transcript with the old conversation in it.
        try scratch.append([old, reply("msg_new", at: "2026-10-22T09:00:00.000Z")], to: scratch.file("resumed.jsonl"))
        ledger.ingest(scratch.file("resumed.jsonl"), now: now, calendar: utc)
        let days = ledger.history(days: 5, now: now, calendar: utc)
        #expect(days[0].requests == 1)
        #expect(days[0].counts.input == 50)
    }

    @Test func historyIsKeptForNinetyDays() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        try scratch.append([reply("msg_1", at: "2026-10-20T10:00:00.000Z")], to: scratch.file())
        let ledger = UsageLedger()
        ledger.ingest(scratch.file(), now: date("2026-10-20T11:00:00.000Z"), calendar: utc)
        ledger.prune(now: date("2026-10-22T11:00:00.000Z"), calendar: utc)
        let later = date("2027-01-10T11:00:00.000Z")  // 82 days on
        ledger.prune(now: later, calendar: utc)
        #expect(ledger.history(days: 90, now: later, calendar: utc).contains { $0.requests == 1 })
        let muchLater = date("2027-02-01T11:00:00.000Z")
        ledger.prune(now: muchLater, calendar: utc)
        #expect(!ledger.history(days: 120, now: muchLater, calendar: utc).contains { $0.requests == 1 })
    }
}

@Suite("Cost estimates")
struct CostEstimateTests {
    @Test func modelsMatchTheirOwnPriceNotAShorterNames() {
        #expect(ModelPrices.price(for: "claude-opus-4-5-20251101")?.input == 5)
        #expect(ModelPrices.price(for: "claude-opus-4-20250514")?.input == 15)
        #expect(ModelPrices.price(for: "claude-opus-4-1-20250805")?.input == 15)
        #expect(ModelPrices.price(for: "claude-opus-5-5")?.input == 4)
        #expect(ModelPrices.price(for: "claude-opus-5")?.input == 5)
        #expect(ModelPrices.price(for: "us.anthropic.claude-sonnet-4-5-20250929-v1:0")?.input == 3)
        #expect(ModelPrices.price(for: "claude-opus-4-5@20251101")?.input == 5)
        #expect(ModelPrices.price(for: "claude-sonnet-4-6[1m]")?.input == 3)
        #expect(ModelPrices.price(for: "claude-3-5-haiku-20241022")?.input == 0.8)
        #expect(ModelPrices.price(for: "gpt-5") == nil)
        #expect(ModelPrices.price(for: "claude-opus-45") == nil, "a name part must end where the table's does")
    }

    @Test func aReplyCostsWhatItsTokensDo() throws {
        let record = try #require(ClaudeTranscript.usageRecord(in: Fixture.data(Fixture.claudeAssistant())))
        // Opus 5.5: $4 in, $20 out, $0.20 cache reads, an hour's cache write at 2× input.
        let dollars: Double = 10 * 4 + 200 * 20 + 300 * 8 + 4_000 * 0.2
        let expected = dollars / 1_000_000
        let cost = try #require(ModelPrices.cost(of: record.counts, model: record.model))
        #expect(abs(cost - expected) < 1e-12)
        let fiveMinute = TokenCounts(cacheWrite: 1_000_000)
        #expect(ModelPrices.cost(of: fiveMinute, model: "claude-sonnet-4-6") == 3.75)
    }

    @Test func longPromptsCostMoreWhereTheModelSaysSo() {
        let long = TokenCounts(input: 250_000, output: 1_000)
        let premium: Double = 250_000 * 6 + 1_000 * 22.5, standard: Double = 250_000 * 3 + 1_000 * 15
        #expect(ModelPrices.cost(of: long, model: "claude-sonnet-4-5") == premium / 1_000_000)
        #expect(ModelPrices.cost(of: long, model: "claude-sonnet-4-6") == standard / 1_000_000)
    }

    @Test func unknownModelsAreLeftOutAndCounted() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file()
        try scratch.append([reply("msg_1", at: "2026-10-22T11:00:00.000Z", input: 1_000_000), reply("msg_2", at: "2026-10-22T11:05:00.000Z", model: "my-proxy-model")], to: url)
        let now = date("2026-10-22T12:00:00.000Z")
        let ledger = UsageLedger()
        ledger.ingest(url, now: now, calendar: utc)
        let summary = ledger.summary(now: now, calendar: utc)
        #expect(summary.todayCost.dollars == 4)
        #expect(summary.todayCost.unpricedRequests == 1)
        #expect(!summary.todayCost.isComplete)
        #expect(summary.windowCost == summary.todayCost)
    }
}

@Suite("Codex usage")
struct CodexUsageTests {
    private func tokenCount(_ total: Int, at time: String) -> String {
        Fixture.codexTokenCount(total: total).replacingOccurrences(of: "2026-10-16T15:20:00.000Z", with: time)
    }

    @Test func addsWhatTheRunningTotalGrewPerDay() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file("rollout.jsonl")
        try scratch.append([Fixture.codexMeta, tokenCount(1_000, at: "2026-10-21T23:00:00.000Z"),
                            tokenCount(1_000, at: "2026-10-21T23:30:00.000Z"),  // repeated, nothing new
                            tokenCount(2_500, at: "2026-10-22T00:30:00.000Z")], to: url)
        let ledger = CodexUsageLedger()
        let now = date("2026-10-22T08:00:00.000Z")
        ledger.ingest(url, now: now, calendar: utc)
        #expect(ledger.todayTokens(now: now, calendar: utc) == 1_500)
        #expect(ledger.history(days: 2, now: now, calendar: utc).map(\.tokens) == [1_000, 1_500])

        try scratch.append([tokenCount(4_000, at: "2026-10-22T07:00:00.000Z")], to: url)
        ledger.ingest(url, now: now, calendar: utc)
        #expect(ledger.todayTokens(now: now, calendar: utc) == 3_000)

        // Saved and restored, an unchanged file adds nothing.
        let saved = scratch.file("codex.json")
        try ledger.save(to: saved)
        let restored = try #require(CodexUsageLedger.load(from: saved))
        restored.ingest(url, now: now, calendar: utc)
        #expect(restored.todayTokens(now: now, calendar: utc) == 3_000)
        #expect(!restored.hasUnsavedChanges)
    }

    @Test func aFileReadAgainAddsOnlyNewGrowth() throws {
        let scratch = Scratch()
        defer { scratch.remove() }
        let url = scratch.file("rollout.jsonl")
        try scratch.append([tokenCount(1_000, at: "2026-10-22T01:00:00.000Z")], to: url)
        let ledger = CodexUsageLedger()
        let now = date("2026-10-22T08:00:00.000Z")
        ledger.ingest(url, now: now, calendar: utc)
        // Replaced by a copy with one more total: only that growth counts.
        try Data((tokenCount(1_000, at: "2026-10-22T01:00:00.000Z") + "\n" + tokenCount(1_200, at: "2026-10-22T02:00:00.000Z") + "\n").utf8)
            .write(to: url, options: .atomic)
        ledger.ingest(url, now: now, calendar: utc)
        #expect(ledger.todayTokens(now: now, calendar: utc) == 1_200)
    }
}

@Suite("Marked line scanning")
struct MarkedLineScanTests {
    @Test func aLineWithTwoMarkersComesOnceWithBothHits() {
        let data = Fixture.data("x\nab one cd two\nnothing\ntwo only\npartial one")
        var lines: [(String, [Int?])] = []
        let consumed = JSONLScanner.forEachLine(containing: ["one", "two"], in: data) { line, hits in
            lines.append((String(decoding: line, as: UTF8.self), hits))
        }
        #expect(lines.map(\.0) == ["ab one cd two", "two only"])
        #expect(lines[0].1 == [3, 10])
        #expect(lines[1].1 == [nil, 0])
        #expect(consumed == data.count - "partial one".count, "the trailing partial line waits")
    }

    @Test func noCompleteLineMeansNothingConsumed() {
        var calls = 0
        #expect(JSONLScanner.forEachLine(containing: ["one"], in: Fixture.data("one but unfinished")) { _, _ in calls += 1 } == 0)
        #expect(calls == 0)
    }

    @Test func aMarkerRepeatedOnALineCountsOnce() {
        var hits: [[Int?]] = []
        JSONLScanner.forEachLine(containing: ["a"], in: Fixture.data("a a a\nb\na\n")) { _, found in hits.append(found) }
        #expect(hits == [[0], [0]])
    }

    @Test func aMarkerOnlyInTheTrailingPartialLineWaits() {
        var lines: [String] = []
        let data = Fixture.data("one\nnothing\ntwo unfinished")
        let consumed = JSONLScanner.forEachLine(containing: ["two"], in: data) { line, _ in
            lines.append(String(decoding: line, as: UTF8.self))
        }
        #expect(lines.isEmpty)
        #expect(consumed == "one\nnothing\n".utf8.count, "complete lines without a marker are still consumed")
    }

    @Test func linesAreFoundFarFromTheLastHit() {
        // Many plain lines between hits: each line handed over must start at its own start.
        let filler = Array(repeating: #"{"type":"user"}"#, count: 500).joined(separator: "\n")
        let data = Fixture.data("mark first\n\(filler)\nlast mark\n\(filler)\n")
        var lines: [(String, [Int?])] = []
        JSONLScanner.forEachLine(containing: ["mark"], in: data) { line, hits in lines.append((String(decoding: line, as: UTF8.self), hits)) }
        #expect(lines.map(\.0) == ["mark first", "last mark"])
        #expect(lines.map(\.1) == [[0], [5]])
    }

    @Test func lastRangeSearchesBackwards() {
        let line = Fixture.data(#"{"usage":{"x":1},"y":{"usage":{"z":2}},"type":"t"}"#)
        let range = JSONLScanner.lastRange(of: #""usage":{"#, in: line, before: 45)
        #expect(range?.lowerBound == 22)
        #expect(JSONLScanner.lastRange(of: "missing", in: line, before: 45) == nil)
    }
}
