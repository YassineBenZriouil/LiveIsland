import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Links and formatting edges")
struct LinkAndFormatTests {
    @Test func timerLinksTakeOnlyMinutesThatMakeSense() {
        #expect(LinkValue.timerMinutes("25") == 25)
        #expect(LinkValue.timerMinutes("0.5") == 0.5)
        #expect(LinkValue.timerMinutes("1440") == 1_440)
        #expect(LinkValue.timerMinutes("1441") == 1_440, "longer than a day becomes a day")
        #expect(LinkValue.timerMinutes("1e20") == 1_440)
        #expect(LinkValue.timerMinutes("inf") == nil)
        #expect(LinkValue.timerMinutes("-inf") == nil)
        #expect(LinkValue.timerMinutes("nan") == nil)
        #expect(LinkValue.timerMinutes("0") == nil)
        #expect(LinkValue.timerMinutes("-5") == nil)
        #expect(LinkValue.timerMinutes("ten") == nil)
        #expect(LinkValue.timerMinutes("") == nil)
    }

    @Test func switchLinksNameTheBestOrANumber() {
        #expect(LinkValue.switchTarget("best") == .best)
        #expect(LinkValue.switchTarget("Best") == .best)
        #expect(LinkValue.switchTarget("2") == .number(2))
        #expect(LinkValue.switchTarget("0") == nil)
        #expect(LinkValue.switchTarget("-1") == nil)
        #expect(LinkValue.switchTarget("+3") == nil)
        #expect(LinkValue.switchTarget("2.5") == nil)
        #expect(LinkValue.switchTarget("٣") == nil, "only ASCII digits")
        #expect(LinkValue.switchTarget("99999999999999999999") == nil)
        #expect(LinkValue.switchTarget("") == nil)
        #expect(LinkValue.switchTarget(nil) == nil)
    }

    @Test func clocksAndSpansNeverTrap() {
        #expect(Format.clock(.infinity) == Format.clock(Format.longestSeconds))
        #expect(Format.clock(-.infinity) == "0:00")
        #expect(Format.clock(.nan) == "0:00")
        #expect(Format.clock(1e20) == Format.clock(Format.longestSeconds))
        #expect(Format.clock(-30) == "0:00")
        #expect(Format.span(.infinity) == Format.span(Format.longestSeconds))
        #expect(Format.span(.nan) == "0s")
        #expect(Format.span(-.infinity) == "0s")
        #expect(Format.span(1e300) == "11574074d 1h")
        #expect(Format.until(.distantFuture, from: Date()).hasPrefix("in "))
        // A day-long timer, the longest a link can start.
        #expect(Format.clock(LinkValue.longestTimerMinutes * 60) == "24:00:00")
    }

    @Test func tokensRoundBeforeChoosingTheUnit() {
        #expect(Format.tokens(999) == "999")
        #expect(Format.tokens(1_000) == "1K")
        #expect(Format.tokens(99_960) == "100K")
        #expect(Format.tokens(999_499) == "999K")
        #expect(Format.tokens(999_500) == "1M")
        #expect(Format.tokens(999_950) == "1M")
        #expect(Format.tokens(1_049_999) == "1M")
        #expect(Format.tokens(1_050_000) == "1.1M")
        #expect(Format.tokens(999_950_000) == "1B")
        #expect(Format.tokens(1_000_000_000_000) == "1000B", "B is the last unit")
        #expect(Format.tokens(0) == "0")
        #expect(Format.tokens(-5) == "-5", "never a unit below a thousand")
        #expect(Format.tokens(9_949) == "9.9K")
        #expect(Format.tokens(9_950) == "10K", "one decimal rounds up to the next whole")
        #expect(Format.tokens(99_949) == "99.9K")
        #expect(Format.tokens(99_950) == "100K", "from 100 on, whole numbers")
        #expect(Format.tokens(100_499) == "100K")
        #expect(Format.tokens(999_949) == "1M", "999.9K rounds to 1000K")
        #expect(Format.tokens(999_499_999) == "999M")
        #expect(Format.tokens(999_500_000) == "1B")
        #expect(!Format.tokens(Int.max).isEmpty)
    }

    @Test func aWindowWithoutItsLengthIsJustALimit() throws {
        let line = #"{"timestamp":"2026-10-16T15:20:00.000Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.5,"resets_at":1792837722},"secondary":{"used_percent":40.0,"window_minutes":0,"resets_at":1793000000}}}}"#
        let limits = try #require(CodexRollout.limits(in: Fixture.data(line)))
        #expect(limits.primary?.label == "Limit")
        #expect(limits.secondary?.label == "Limit")
        #expect(limits.primary?.shortLabel == "Limit")
        #expect(RateLimitWindow(usedPercent: 1, windowMinutes: 0, resetsAt: nil, model: "Fable").shortLabel == "Fable limit")
        #expect(RateLimitWindow(usedPercent: 1, windowMinutes: 300, resetsAt: nil).label == "5-hour")
        #expect(RateLimitWindow(usedPercent: 1, windowMinutes: 45, resetsAt: nil).label == "45-minute")
    }

    @Test func fastTimestampsRejectImpossibleTimesAndJunk() {
        #expect(Format.utcTimestamp("2026-10-22T13:52:07.633Z") != nil)
        #expect(Format.utcTimestamp("2026-10-22T23:59:59Z") != nil)
        #expect(Format.utcTimestamp("2024-02-29T00:00:00Z") != nil, "a leap day")
        #expect(Format.utcTimestamp("2026-10-22T24:00:00Z") == nil)
        #expect(Format.utcTimestamp("2026-10-22T13:60:00Z") == nil)
        #expect(Format.utcTimestamp("2026-10-22T13:52:61Z") == nil)
        #expect(Format.utcTimestamp("2026-02-30T00:00:00Z") == nil)
        #expect(Format.utcTimestamp("2026-02-29T00:00:00Z") == nil, "not a leap year")
        #expect(Format.utcTimestamp("1900-02-29T00:00:00Z") == nil, "centuries skip the leap day")
        #expect(Format.utcTimestamp("2026-04-31T00:00:00Z") == nil)
        #expect(Format.utcTimestamp("2026-10-22T13:52:07ZZ") == nil)
        #expect(Format.utcTimestamp("2026-10-22T13:52:07.633Z junk") == nil)
        #expect(Format.utcTimestamp("2026-10-22T13:52:07.12345678901234567890Zjunk") == nil,
                "junk past the first 40 bytes is still junk")
        #expect(Format.utcTimestamp("2026-10-22T13:52:07.6x3Z") == nil)    }
}
