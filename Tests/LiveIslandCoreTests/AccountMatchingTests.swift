import Foundation
import Testing
@testable import LiveIslandCore

/// Lines and logins shaped like the real ones (Claude Code's `oauthAccount`, claude-swap's and
/// ccswap's JSON), with made-up accounts.
private enum Matching {
    static func oauth(email: String, uuid: String, org: String, tier: String) -> String {
        #"{"accountUuid":"\#(uuid)","emailAddress":"\#(email)","organizationUuid":"\#(org)","displayName":"","organizationRateLimitTier":"\#(tier)","organizationName":"\#(email)'s Organization"}"#
    }

    static func identity(email: String, uuid: String, org: String, tier: String = "default_claude_max_20x") -> ClaudeAccountIdentity {
        ClaudeAccountIdentity.parse(Data(oauth(email: email, uuid: uuid, org: org, tier: tier).utf8))!
    }

    static let hugePoll = #"{"schemaVersion":1,"event":"poll","ts":"2026-10-28T11:01:49Z","active":{"number":1e30,"email":"main@example.com"},"threshold":1e300,"windowsPct":{"1":{"5h":1e300,"7d":-1e300,"Fable":12.5}}}"#
    static let hugeSettings = #"{"schemaVersion":1,"settings":[{"key":"autoswitch.threshold","value":1e300,"isSet":true},{"key":"autoswitch.hysteresisPct","value":-9.3e18,"isSet":true},{"key":"autoswitch.cooldown","value":120,"isSet":true}]}"#
    static let hugeList = #"{"schemaVersion":1,"accounts":[{"number":1e20,"email":"big@example.com","active":false},{"number":"99999999999999999999","email":"text@example.com","active":false},{"number":2,"email":"ok@example.com","active":true,"usageStatus":"ok","usage":{"sevenDay":{"pct":1e300}}}]}"#
    static let hugeCodexPoll = #"{"schemaVersion":1,"event":"poll","ts":"2026-10-28T11:01:49Z","active":{"number":1,"email":"main@example.com"},"headroomPct":{"1":1e300,"2":-1e300},"threshold":9e18}"#
    static let codexList = #"{"provider":"codex","accounts":[{"number":1,"email":"main@example.com","authMode":"chatgpt","planType":"plus","active":true,"disabled":false}]}"#
    static let hugeCodexUsage = #"{"provider":"codex","accounts":[{"number":1,"usage":{"five_hour":{"pct":1e300},"reset_credits":{"available":1e40}}}]}"#
}

@Suite("Account matching")
struct AccountMatchingTests {
    let now = Date(timeIntervalSince1970: 1_792_850_400)

    /// A and B both at 5-hour windows resetting on the same hour. B is in use since `switchAt`.
    private func twoAccountsOnTheSameHour() -> (book: AccountBook, a: ClaudeAccountIdentity, b: ClaudeAccountIdentity, reset: Date, switchAt: Date) {
        let a = Matching.identity(email: "a@example.com", uuid: "acct-a", org: "org-a")
        let b = Matching.identity(email: "b@example.com", uuid: "acct-b", org: "org-b")
        let reset = now.addingTimeInterval(3_600)
        var book = AccountBook()
        book.setActive(a, at: now.addingTimeInterval(-1_000))
        let switchAt = now.addingTimeInterval(-500)
        book.setActive(b, at: switchAt)
        book.entries[a.key]?.fiveHour = RateLimitWindow(usedPercent: 30, windowMinutes: 300, resetsAt: reset)
        book.entries[a.key]?.limitsObservedAt = now.addingTimeInterval(-900)
        book.entries[b.key]?.fiveHour = RateLimitWindow(usedPercent: 10, windowMinutes: 300, resetsAt: reset.addingTimeInterval(20))
        book.entries[b.key]?.limitsObservedAt = now.addingTimeInterval(-600)
        return (book, a, b, reset, switchAt)
    }

    @Test func aReadingMatchingTwoAccountsGoesToTheOneInUseWhenTheSessionIsNew() {
        var (book, a, b, reset, switchAt) = twoAccountsOnTheSameHour()
        let limits = ClaudeUsageLimits(fiveHour: RateLimitWindow(usedPercent: 44, windowMinutes: 300, resetsAt: reset), sevenDay: nil, observedAt: now)
        let placed = book.record(limits, sessionStartedAt: switchAt.addingTimeInterval(60))
        #expect(placed)
        #expect(book.entries[b.key]?.fiveHour?.usedPercent == 44)
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 30)
    }

    @Test func aReadingFromAnOlderSessionGoesToTheNewestReadingOfTheTwo() {
        var (book, a, b, reset, _) = twoAccountsOnTheSameHour()
        // B was read last: an older session's report could be either, and B is the likelier.
        let limits = ClaudeUsageLimits(fiveHour: RateLimitWindow(usedPercent: 55, windowMinutes: 300, resetsAt: reset), sevenDay: nil, observedAt: now)
        let placed = book.record(limits, sessionStartedAt: now.addingTimeInterval(-2_000))
        #expect(placed)
        #expect(book.entries[b.key]?.fiveHour?.usedPercent == 55)
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 30)
        // Now A is the newest reading.
        book.entries[a.key]?.limitsObservedAt = now.addingTimeInterval(30)
        let later = ClaudeUsageLimits(fiveHour: RateLimitWindow(usedPercent: 60, windowMinutes: 300, resetsAt: reset), sevenDay: nil,
                                      observedAt: now.addingTimeInterval(60))
        book.record(later, sessionStartedAt: nil)
        #expect(book.entries[a.key]?.fiveHour?.usedPercent == 60 && book.entries[b.key]?.fiveHour?.usedPercent == 55)
    }

    @Test func aRefusalMatchingTwoAccountsFollowsTheSameRules() {
        var (book, a, b, reset, switchAt) = twoAccountsOnTheSameHour()
        book.record(ClaudeLimitNotice(status: "rejected", type: "five_hour", resetsAt: reset, observedAt: now),
                    sessionStartedAt: switchAt.addingTimeInterval(10))
        #expect(book.entries[b.key]?.fiveHour?.usedPercent == 100 && book.entries[a.key]?.fiveHour?.usedPercent == 30)

        var (other, a2, b2, _, _) = twoAccountsOnTheSameHour()
        other.entries[a2.key]?.limitsObservedAt = now.addingTimeInterval(-100)
        other.record(ClaudeLimitNotice(status: "rejected", type: "five_hour", resetsAt: reset, observedAt: now),
                     sessionStartedAt: now.addingTimeInterval(-5_000))
        #expect(other.entries[a2.key]?.fiveHour?.usedPercent == 100, "the newest reading wins for an older session")
        #expect(other.entries[b2.key]?.fiveHour?.usedPercent == 10)
    }

    @Test func aFullTieIsSettledTheSameWayEveryTime() {
        let owners = (0..<20).map { _ -> String? in
            let setup = twoAccountsOnTheSameHour()
            var book = setup.book
            book.entries[setup.a.key]?.limitsObservedAt = now
            book.entries[setup.b.key]?.limitsObservedAt = now
            return book.owner(among: [setup.b.key, setup.a.key].shuffled(), sessionStartedAt: nil)
        }
        #expect(Set(owners).count == 1)
        #expect(owners.first == Matching.identity(email: "a@example.com", uuid: "acct-a", org: "org-a").key)
    }

    // MARK: Same email, personal and team

    private func personalAndTeam() -> (book: AccountBook, personal: ClaudeAccountIdentity, team: ClaudeAccountIdentity) {
        let personal = Matching.identity(email: "me@example.com", uuid: "acct-me", org: "org-personal", tier: "default_claude_max_5x")
        let team = Matching.identity(email: "me@example.com", uuid: "acct-me", org: "org-team", tier: "default_claude_team")
        var book = AccountBook()
        book.setActive(personal, at: now.addingTimeInterval(-100))
        book.setActive(team, at: now)
        return (book, personal, team)
    }

    @Test func aPersonalRowWithoutAnOrganizationIsThePersonalAccount() {
        let (book, personal, team) = personalAndTeam()
        let rows = [
            ClaudeSwapAccount(number: 1, email: "me@example.com", organizationName: nil, organizationUUID: nil, isActive: false,
                              usageStatus: "ok", fiveHour: nil, sevenDay: nil, usageFetchedAt: now, isDisabled: false),
            ClaudeSwapAccount(number: 2, email: "ME@example.com", organizationName: "Team", organizationUUID: "org-team", isActive: true,
                              usageStatus: "ok", fiveHour: nil, sevenDay: nil, usageFetchedAt: now, isDisabled: false),
        ]
        for _ in 0..<10 {
            let accounts = ClaudeAccounts.merge(book: book, claudeSwap: rows.shuffled(), switcher: .claudeSwap, now: now)
            #expect(accounts.map(\.claudeSwapNumber) == [2, 1])
            #expect(accounts[0].identity.organizationUUID == team.organizationUUID && accounts[0].identity.plan == "Team")
            #expect(accounts[1].identity.organizationUUID == personal.organizationUUID && accounts[1].identity.plan == "Max 5x")
        }
    }

    @Test func aPersonalRowAloneStillSkipsTheTeamEntry() {
        // claude-swap manages only the personal login; the team one is in use from elsewhere.
        let (book, personal, _) = personalAndTeam()
        let row = ClaudeSwapAccount(number: 1, email: "me@example.com", organizationName: nil, organizationUUID: nil, isActive: false,
                                    usageStatus: "ok", fiveHour: nil, sevenDay: nil, usageFetchedAt: now, isDisabled: false)
        let known = book.entry(email: row.email, organization: nil, isActive: false, claimedOrganizations: [])
        #expect(known?.identity.key == personal.key)
        let accounts = ClaudeAccounts.merge(book: book, claudeSwap: [row], switcher: .claudeSwap, now: now)
        #expect(accounts.first?.identity.organizationUUID == personal.organizationUUID)
    }

    @Test func aCodexRowInUseIsTheEntryInUse() {
        var book = AccountBook()
        let home = ClaudeAccountIdentity(accountUUID: "user-1", email: "main@example.com", name: "Home", organizationUUID: "ws-home", tier: "plus")
        let work = ClaudeAccountIdentity(accountUUID: "user-1", email: "main@example.com", name: "Work", organizationUUID: "ws-work", tier: "team")
        book.setActive(work, at: now.addingTimeInterval(-10))
        book.setActive(home, at: now)
        let rows = [CodexSwapAccount(number: 1, email: "Main@example.com", isActive: true)]
        for _ in 0..<10 {
            #expect(CodexAccounts.merge(book: book, ccswap: rows, now: now).first?.identity.name == "Home")
        }
    }

    // MARK: Numbers that don't fit

    @Test func hugeNumbersNeverCrash() throws {
        let poll = try #require(ClaudeSwapEvent.parse(Data(Matching.hugePoll.utf8))?.event)
        #expect(poll.summary == "Checked: on main@example.com · #1 999%/0% Fable 13% · switch at \(Int.max)%")
        guard case .poll(let active, _, _) = poll else { Issue.record("not a poll"); return }
        #expect(active?.number == nil, "1e30 is no account's number")

        let settings = try #require(ClaudeSwapSetting.parse(Data(Matching.hugeSettings.utf8)))
        #expect(settings.map(\.value) == ["1e+300", "-9.3e+18", "120"])

        let accounts = try #require(ClaudeSwapJSON.accounts(from: Data(Matching.hugeList.utf8)))
        #expect(accounts.map(\.number) == [2])

        let codex = try #require(CodexSwapEvent.parse(Data(Matching.hugeCodexPoll.utf8))?.event)
        #expect(codex.summary == "Checked: on main@example.com · #1 0%, #2 999% · switch at 9000000000000000000%")
        let codexAccounts = try #require(CodexSwapJSON.accounts(list: Data(Matching.codexList.utf8), usage: Data(Matching.hugeCodexUsage.utf8)))
        #expect(codexAccounts.first?.bankedResets == nil && codexAccounts.first?.fiveHour?.usedPercent == 1e300)
    }

    @Test func wholeNumbersStayInRange() {
        #expect(SwitcherOutput.wholeNumber(.infinity) == .max && SwitcherOutput.wholeNumber(-.infinity) == .min)
        #expect(SwitcherOutput.wholeNumber(.nan) == 0 && SwitcherOutput.wholeNumber(9.9) == 9)
        #expect(SwitcherOutput.number("12") == 12 && SwitcherOutput.number(7) == 7 && SwitcherOutput.number(2.5) == nil)
    }

    // MARK: Codex logins

    @Test func onlyARealUnauthorizedNeedsALogin() {
        func account(_ error: String?) -> CodexSwapAccount { CodexSwapAccount(number: 1, email: "a@example.com", usageError: error) }
        #expect(account("http-401").needsLogin)
        #expect(account("HTTP 401 Unauthorized").needsLogin)
        #expect(account("unauthorized").needsLogin)
        #expect(!account("timed out after 1401ms").needsLogin)
        #expect(!account("http-4010").needsLogin)
        #expect(!account("http-429").needsLogin && !account(nil).needsLogin)
    }

    // MARK: Plans

    @Test func anUnknownClaudeTierNeverReadsAsAChatGPTPlan() {
        func plan(_ tier: String) -> String? { ClaudeAccountIdentity(accountUUID: "u", email: "e", tier: tier).plan }
        #expect(plan("default_claude_ultra") == "Ultra")
        #expect(plan("default_claude_ai") == nil, "no plan rather than a made-up one")
        #expect(plan("default_raven") == "Raven")
        #expect(plan("default_claude_max_20x") == "Max 20x")
        #expect(plan("self_serve") == "Self Serve", "a new ChatGPT plan reads as its words")
        #expect(plan("plus") == "Plus")
    }

    // MARK: Events

    @Test func eventsCompareWhatTheySayNotHowTheyRead() throws {
        let first = try #require(ClaudeSwapEvent.parse(Data(#"{"schemaVersion":1,"event":"poll","windowsPct":{"1":{"5h":15.2,"7d":67.0}},"threshold":90.0}"#.utf8))?.event)
        let close = try #require(ClaudeSwapEvent.parse(Data(#"{"schemaVersion":1,"event":"poll","windowsPct":{"1":{"5h":15.4,"7d":67.0}},"threshold":90.0}"#.utf8))?.event)
        let same = try #require(ClaudeSwapEvent.parse(Data(#"{"schemaVersion":1,"event":"poll","threshold":90.0,"windowsPct":{"1":{"7d":67.0,"5h":15.2}}}"#.utf8))?.event)
        #expect(first.summary == close.summary)
        #expect(first != close, "the same line, different numbers")
        #expect(first == same)
        #expect(ClaudeSwapEvent.error(message: "x", transient: true) != .error(message: "x", transient: false))
        #expect(ClaudeSwapEvent.other("poll") != first, "an unknown kind named like a known one")
        #expect(ClaudeSwapEvent.switched(trigger: "proactive", from: nil, to: .init(number: 2, email: nil), dryRun: false)
            == .switched(trigger: "proactive", from: nil, to: .init(number: 2, email: nil), dryRun: false))
    }

    @Test func eachToolReadsOnlyItsOwnUpdateNotice() {
        #expect(SwitcherOutput.newerVersion(of: "ccswap", in: "A newer version of ccswap is available (0.43.0)") == "0.43.0")
        #expect(SwitcherOutput.newerVersion(of: "ccswap", in: "A newer version of ccswap is available (soon)") == nil)
        #expect(ClaudeSwapCommand.newerVersion(in: "A newer version of ccswap is available (0.43.0)") == nil)
    }

    @Test func helpStaysWithCodex() {
        #expect(CodexSwapCommand.arguments("--help") == ["codex", "--help"])
        #expect(CodexSwapCommand.arguments("--version") == ["--version"])
    }
}
