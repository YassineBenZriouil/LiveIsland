import Foundation
import Testing
@testable import LiveIslandCore

private func date(_ text: String) -> Date { Format.date(iso8601: text)! }

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A reply as Claude Code logs it, with only fresh input for easy sums.
private func reply(_ id: String, at time: String, input: Int, model: String = "claude-opus-5-5", cwd: String = "/Users/me/Code/app") -> String {
    Fixture.claudeAssistant(id: id, at: time, input: input, output: 0, cacheWrite: 0, cacheRead: 0)
        .replacingOccurrences(of: #""model":"claude-opus-5-5""#, with: #""model":"\#(model)""#)
        .replacingOccurrences(of: #""cwd":"/Users/me/Code/app""#, with: #""cwd":"\#(cwd)""#)
}

/// A ledger that read `lines` from a scratch transcript, and its history up to `now`.
private func history(_ lines: [String], days: Int, now: Date) throws -> [UsageDay] {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("report-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("session.jsonl")
    try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url)
    let ledger = UsageLedger()
    ledger.ingest(url, now: now, calendar: utc)
    ledger.prune(now: now, calendar: utc)
    return ledger.history(days: days, now: now, calendar: utc)
}

@Suite("Usage report")
struct UsageReportTests {
    @Test func sumsThePeriodAndScalesTheSparklineToTheBusiestDay() throws {
        let now = date("2026-10-22T10:00:00.000Z")
        let days = try history([
            reply("msg_1", at: "2026-10-20T10:00:00.000Z", input: 1_000_000),
            reply("msg_2", at: "2026-10-22T09:00:00.000Z", input: 500_000),
        ], days: 3, now: now)
        let report = UsageReport(history: days)
        // Opus 5.5 at $4 per million input tokens.
        #expect(abs(report.cost.dollars - 6) < 1e-9)
        #expect(report.tokens == 1_500_000)
        #expect(report.trendIsCost)
        #expect(report.trend == [1, 0, 0.5])
        #expect(report.activeDays == 2)
        #expect(!report.isEmpty)
    }

    @Test func breaksDownByModelAndProjectFoldingTheRestIntoOther() throws {
        let now = date("2026-10-22T10:00:00.000Z")
        let days = try history([
            reply("msg_1", at: "2026-10-21T10:00:00.000Z", input: 400, model: "claude-opus-5-5", cwd: "/Users/me/Code/app"),
            reply("msg_2", at: "2026-10-21T11:00:00.000Z", input: 300, model: "claude-sonnet-4-5-20250929", cwd: "/Users/me/Code/api"),
            reply("msg_3", at: "2026-10-22T08:00:00.000Z", input: 200, model: "claude-haiku-4-5-20251001", cwd: "/Users/me/Code/web"),
            reply("msg_4", at: "2026-10-22T09:00:00.000Z", input: 100, model: "claude-3-5-haiku-20241022", cwd: "/Users/me/Code/cli"),
        ], days: 2, now: now)
        let report = UsageReport(history: days, top: 2)
        #expect(report.models.map(\.name) == ["Opus 5.5", "Sonnet 4.5", "Other"])
        #expect(report.projects.map(\.name) == ["app", "api", "Other"])
        #expect(report.projects.last?.tokens == 300)
        // Shares are of the cost: $1.6, $0.9, then $0.2 + $0.08 of $2.78 per million.
        let shares = report.models.map(\.share)
        #expect(abs(shares.reduce(0, +) - 1) < 1e-9)
        #expect(abs(shares[0] - 1_600.0 / 2_780) < 1e-9)
    }

    @Test func modelsWithoutAPriceFollowTokensAndSayTheEstimateIsPartial() throws {
        let now = date("2026-10-22T10:00:00.000Z")
        let days = try history([
            reply("msg_1", at: "2026-10-22T08:00:00.000Z", input: 300, model: "my-proxy-model"),
            reply("msg_2", at: "2026-10-22T09:00:00.000Z", input: 100, model: "my-proxy-model"),
        ], days: 2, now: now)
        let report = UsageReport(history: days)
        #expect(!report.trendIsCost, "nothing had a price: the sparkline shows tokens")
        #expect(report.trend == [0, 1])
        #expect(!report.cost.isComplete)
        #expect(Format.cost(report.cost) == "$0+")
        #expect(report.models.map(\.name) == ["my-proxy-model"])
        #expect(report.models.first?.share == 1)
    }

    @Test func aQuietMonthIsEmpty() {
        let report = UsageReport(history: [UsageDay(start: date("2026-10-22T00:00:00.000Z"), buckets: [])])
        #expect(report.isEmpty)
        #expect(report.trend == [0])
        #expect(report.models.isEmpty)
        #expect(UsageReport.levels([]) == [])
    }

    @Test func codexDaysBecomeSparklineHeights() {
        let start = date("2026-10-20T00:00:00.000Z")
        let days = [0, 4_000, 2_000].enumerated().map { CodexUsageDay(start: start.addingTimeInterval(Double($0.offset) * 86_400), tokens: $0.element) }
        #expect(UsageReport.levels(codex: days) == [0, 1, 0.5])
    }

    @Test(arguments: [
        ("claude-opus-4-5-20251101", "Opus 4.5"),
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-4-5[1m]", "Sonnet 4.5"),
        ("claude-opus-4-5@20251101", "Opus 4.5"),
        ("us.anthropic.claude-sonnet-4-5-20250929-v1:0", "Sonnet 4.5"),
        ("claude-3-5-haiku-20241022", "Haiku 3.5"),
        ("claude-opus-4", "Opus 4"),
        ("<synthetic>", "<synthetic>"),
    ])
    func shortModelNames(id: String, expected: String) {
        #expect(ModelName.short(id) == expected)
    }

    @Test(arguments: [
        (0.0, "$0"), (0.004, "<$0.01"), (0.42, "$0.42"), (4.2, "$4.20"), (38.456, "$38.46"),
        (142.3, "$142"), (1_234, "$1.2K"), (12_000, "$12K"),
    ])
    func dollars(value: Double, expected: String) {
        #expect(Format.dollars(value) == expected)
    }
}
