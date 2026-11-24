import Foundation
import Testing
@testable import LiveIslandCore

@Suite("What wins the closed notch")
struct ActivityPriorityTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    /// Every case, most important first, as the closed notch should rank them.
    private var ranked: [IslandActivity] {
        [
            .call(app: "FaceTime", since: now),
            .timerFinished,
            .agentNeedsYou(.claude, project: "app"),
            .accountLimit(account: "work@example.com", switchTo: "home@example.com"),
            .accountSwitched(to: "home@example.com"),
            .lowBattery(device: nil, percent: 9),
            .headphonesConnected(name: "AirPods Pro", battery: 80),
            .charging(percent: 40),
            .limitReset(.claude, account: "work@example.com"),
            .agentDone(.codex, project: "api"),
            .eventSoon(title: "Standup", startsAt: now),
            .limitWaiting(.claude, account: "work@example.com", resetsAt: now),
            .cameraOn(app: nil),
            .microphoneOn(app: "Zoom"),
            .timer(endsAt: now),
            .limitForecast(.claude, account: "work@example.com", runsOutAt: now),
            .agentWorking(.claude, project: "app", since: now),
            .nowPlaying(title: "Song", isPlaying: true),
            .nowPlaying(title: "Song", isPlaying: false),
        ]
    }

    @Test func everyCaseHasItsPlace() {
        let priorities = ranked.map(\.priority)
        #expect(priorities == priorities.sorted(by: >))
        #expect(Set(priorities).count == priorities.count, "two cases tie, so list order would decide")
    }

    @Test func eachOneWinsOverEverythingBelowIt() {
        for (index, activity) in ranked.enumerated() {
            // Whatever order the rest arrive in, it wins over all of them.
            let below = Array(ranked[index...].dropFirst())
            #expect(IslandActivity.mostImportant(below.reversed() + [activity]) == activity)
            #expect(IslandActivity.mostImportant([activity] + below) == activity)
        }
    }

    @Test func aMeetingBeatsWaitingForALimit() {
        let wait = IslandActivity.limitWaiting(.claude, account: "a", resetsAt: now.addingTimeInterval(7200))
        let meeting = IslandActivity.eventSoon(title: "Standup", startsAt: now.addingTimeInterval(300))
        #expect(IslandActivity.mostImportant([wait, meeting]) == meeting)
        #expect(IslandActivity.mostImportant([wait, .nowPlaying(title: "Song", isPlaying: true)]) == wait)
    }

    @Test func aForecastBeatsTheWorkUsingItUp() {
        let forecast = IslandActivity.limitForecast(.claude, account: "a", runsOutAt: now.addingTimeInterval(1800))
        #expect(IslandActivity.mostImportant([.agentWorking(.claude, project: "app", since: now), forecast]) == forecast)
        #expect(IslandActivity.mostImportant([forecast, .timer(endsAt: now)]) == .timer(endsAt: now))
    }
}

@Suite("Limits: waiting, coming back, running out")
struct LimitMomentsTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ email: String, active: Bool = false, fiveHour: Double? = nil, fiveResets: TimeInterval? = 3600,
                         week: Double? = nil, weekResets: TimeInterval? = 3 * 86_400,
                         switchable: Bool = true) -> Account {
        Account(identity: AccountIdentity(accountUUID: email, email: email), isActive: active,
                fiveHour: fiveHour.map { RateLimitWindow(usedPercent: $0, windowMinutes: 300, resetsAt: fiveResets.map(now.addingTimeInterval)) },
                sevenDay: week.map { RateLimitWindow(usedPercent: $0, windowMinutes: 10_080, resetsAt: weekResets.map(now.addingTimeInterval)) },
                limitsObservedAt: now, switcher: switchable ? .claudeSwap : nil)
    }

    // MARK: Waiting

    @Test func backWhenEveryLimitItReachedResets() {
        // Both windows full: back only when the later one resets.
        let both = account("a@example.com", active: true, fiveHour: 100, week: 100, weekResets: 7200)
        #expect(LimitWait.backAt(both, at: now) == now.addingTimeInterval(7200))
        // The week has room: the 5 hours decide.
        let five = account("a@example.com", active: true, fiveHour: 100, week: 60)
        #expect(LimitWait.backAt(five, at: now) == now.addingTimeInterval(3600))
        // With room, or a reset nobody knows, there's nothing to count down to.
        #expect(LimitWait.backAt(account("a@example.com", fiveHour: 40, week: 60), at: now) == nil)
        #expect(LimitWait.backAt(account("a@example.com", fiveHour: 100, fiveResets: nil), at: now) == nil)
    }

    @Test func theFirstAccountBackIsTheOneToWaitFor() {
        let accounts = [
            account("work@example.com", active: true, fiveHour: 100, fiveResets: 5400),
            account("home@example.com", fiveHour: 100, fiveResets: 1800),
            // Comes back sooner, but can't be switched to from here.
            account("other@example.com", fiveHour: 100, fiveResets: 600, switchable: false),
        ]
        let first = LimitWait.firstBack(accounts, at: now)
        #expect(first?.account.identity.email == "home@example.com")
        #expect(first?.at == now.addingTimeInterval(1800))
    }

    @Test func aResetThatPassedIsNoLongerAWait() {
        let account = account("a@example.com", active: true, fiveHour: 100, fiveResets: 60)
        #expect(LimitWait.backAt(account, at: now.addingTimeInterval(61)) == nil)
    }

    // MARK: Coming back

    @Test func sayingItsBackOnceTheLimitResets() {
        var tracker = LimitReturn()
        let full = account("a@example.com", active: true, fiveHour: 100, fiveResets: 600)
        do { let seen = tracker.observe(full, at: now); #expect(!seen) }
        do { let seen = tracker.observe(full, at: now.addingTimeInterval(300)); #expect(!seen) }
        // The clock passes the reset: the same numbers now read as a fresh window.
        do { let seen = tracker.observe(full, at: now.addingTimeInterval(601)); #expect(seen) }
        // Only once.
        do { let seen = tracker.observe(full, at: now.addingTimeInterval(631)); #expect(!seen) }
    }

    @Test func newNumbersAfterTheResetCountToo() {
        var tracker = LimitReturn()
        do { let seen = tracker.observe(account("a@example.com", active: true, fiveHour: 100, fiveResets: 600), at: now); #expect(!seen) }
        let fresh = Account(identity: AccountIdentity(accountUUID: "a@example.com", email: "a@example.com"), isActive: true,
                            fiveHour: RateLimitWindow(usedPercent: 2, windowMinutes: 300, resetsAt: now.addingTimeInterval(600 + 18_000)))
        do { let seen = tracker.observe(fresh, at: now.addingTimeInterval(590)); #expect(seen, "within the grace of the reset time") }
    }

    @Test func aSwitchIsNotALimitComingBack() {
        var tracker = LimitReturn()
        do { let seen = tracker.observe(account("work@example.com", active: true, fiveHour: 100, fiveResets: 600), at: now); #expect(!seen) }
        do { let seen = tracker.observe(account("home@example.com", active: true, fiveHour: 10), at: now.addingTimeInterval(700)); #expect(!seen) }
    }

    @Test func aDipBeforeTheResetIsAStaleReading() {
        var tracker = LimitReturn()
        do { let seen = tracker.observe(account("a@example.com", active: true, fiveHour: 100, fiveResets: 3600), at: now); #expect(!seen) }
        do { let seen = tracker.observe(account("a@example.com", active: true, fiveHour: 70, fiveResets: 3600), at: now.addingTimeInterval(60)); #expect(!seen) }
        do { let seen = tracker.observe(nil, at: now.addingTimeInterval(4000)); #expect(!seen) }
    }

    // MARK: Running out

    @Test func theFiveHourPaceSaysWhenItRunsOut() {
        // 50% used, 2 hours into the window (it resets in 3): 1 more hour at that pace.
        let window = RateLimitWindow(usedPercent: 50, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600))
        #expect(LimitForecast.runsOut(window, at: now) == now.addingTimeInterval(2 * 3600))
        // 20% in 2 hours: 8 more hours, well after the reset.
        let slow = RateLimitWindow(usedPercent: 20, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600))
        #expect(LimitForecast.runsOut(slow, at: now) == nil)
    }

    @Test func tooLittleToGoOnSaysNothing() {
        // Five minutes in: too soon to tell a pace.
        let early = RateLimitWindow(usedPercent: 30, windowMinutes: 300, resetsAt: now.addingTimeInterval(295 * 60))
        #expect(LimitForecast.runsOut(early, at: now) == nil)
        let little = RateLimitWindow(usedPercent: 5, windowMinutes: 300, resetsAt: now.addingTimeInterval(60))
        #expect(LimitForecast.runsOut(little, at: now) == nil)
        let unknown = RateLimitWindow(usedPercent: 80, windowMinutes: 300, resetsAt: nil)
        #expect(LimitForecast.runsOut(unknown, at: now) == nil)
        let full = RateLimitWindow(usedPercent: 100, windowMinutes: 300, resetsAt: now.addingTimeInterval(60))
        #expect(LimitForecast.runsOut(full, at: now) == nil)
    }

    /// claude-swap's own line for an account running hot this week.
    static let hotWeek = #"""
    {"schemaVersion":1,"activeAccountNumber":1,"accounts":[{"number":1,"email":"work@example.com","active":true,"usageStatus":"ok","usage":{"fiveHour":{"pct":12.0,"resetsAt":"2023-11-14T23:13:20Z"},"sevenDay":{"pct":81.0,"resetsAt":"2023-11-17T22:13:20Z","projectedExhaustionAt":"2023-11-15T01:30:00Z","willLastToReset":false}},"disabled":false}]}
    """#

    @Test func claudeSwapsProjectionDecidesTheWeek() throws {
        let swap = try #require(ClaudeSwapJSON.accounts(from: Data(Self.hotWeek.utf8))?.first)
        let account = Account(identity: AccountIdentity(accountUUID: "u", email: swap.email), isActive: true,
                              fiveHour: swap.fiveHour, sevenDay: swap.sevenDay, switcher: .claudeSwap)
        let projected = try #require(swap.projectedExhaustionAt)
        #expect(swap.willLastToReset == false)
        let out = LimitForecast.runsOut(account, projected: projected, willLastToReset: swap.willLastToReset, at: now)
        #expect(out == projected)
        #expect(LimitForecast.isNear(projected, at: projected.addingTimeInterval(-3600)))
        #expect(!LimitForecast.isNear(projected, at: projected.addingTimeInterval(-3 * 3600)))
        // claude-swap says the week lasts: the week's own average isn't second-guessed.
        #expect(LimitForecast.runsOut(account, projected: projected, willLastToReset: true, at: now) == nil)
    }

    @Test func theEarliestLimitWins() {
        // 5 hours: 50% after 2 h, out in 2 more. Week: 50% after 3 days, out in 3 more.
        let account = Account(identity: AccountIdentity(accountUUID: "u", email: "u@example.com"), isActive: true,
                              fiveHour: RateLimitWindow(usedPercent: 50, windowMinutes: 300, resetsAt: now.addingTimeInterval(3 * 3600)),
                              sevenDay: RateLimitWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400)))
        #expect(LimitForecast.runsOut(account, at: now) == now.addingTimeInterval(2 * 3600))
        var full = account
        full.fiveHour?.usedPercent = 100
        #expect(LimitForecast.runsOut(full, at: now) == nil, "already out: that's a wait, not a forecast")
    }
}

@Suite("Opening briefly")
struct BriefOpenTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func conditions(enabled: Bool = true, reduceMotion: Bool = false, expanded: Bool = false, hovering: Bool = false,
                            unavailable: Bool = false, outranked: Bool = false) -> BriefOpen.Conditions {
        BriefOpen.Conditions(enabled: enabled, reduceMotion: reduceMotion, expanded: expanded, hovering: hovering,
                             unavailable: unavailable, outranked: outranked)
    }

    @Test func opensWhenNothingStandsInTheWay() {
        var brief = BriefOpen()
        do { let seen = brief.shouldOpen(conditions(), at: now); #expect(seen) }
    }

    @Test func staysClosedWhenItWouldBeInTheWay() {
        for blocked in [conditions(enabled: false), conditions(reduceMotion: true), conditions(expanded: true),
                        conditions(hovering: true), conditions(unavailable: true), conditions(outranked: true)] {
            var brief = BriefOpen()
            do { let seen = brief.shouldOpen(blocked, at: now); #expect(!seen) }
            // Being turned away doesn't start the cooldown.
            do { let seen = brief.shouldOpen(conditions(), at: now); #expect(seen) }
        }
    }

    @Test func notTwiceInARow() {
        var brief = BriefOpen()
        do { let seen = brief.shouldOpen(conditions(), at: now); #expect(seen) }
        do { let seen = brief.shouldOpen(conditions(), at: now.addingTimeInterval(10)); #expect(!seen) }
        do { let seen = brief.shouldOpen(conditions(), at: now.addingTimeInterval(BriefOpen.cooldown + 1)); #expect(seen) }
        // A clock set back doesn't hold it closed for good.
        do { let seen = brief.shouldOpen(conditions(), at: now); #expect(seen) }
    }
}
