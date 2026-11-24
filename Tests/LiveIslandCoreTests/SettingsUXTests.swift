import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Pill caption")
struct PillCaptionTests {
    @Test func namesTheTrackOrTheProject() {
        #expect(IslandActivity.nowPlaying(title: "Teardrop", isPlaying: true).caption == "Teardrop")
        #expect(IslandActivity.agentWorking(.claude, project: "LiveIsland", since: Date()).caption == "LiveIsland")
        #expect(IslandActivity.agentNeedsYou(.codex, project: "api").caption == "api")
        #expect(IslandActivity.eventSoon(title: "Standup", startsAt: Date()).caption == "Standup")
        #expect(IslandActivity.call(app: "Microsoft Teams", since: Date()).caption == "Microsoft Teams")
    }

    @Test func staysEmptyWhenTheWingsSayItAll() {
        #expect(IslandActivity.timer(endsAt: Date()).caption == nil)
        #expect(IslandActivity.charging(percent: 80).caption == nil)
        #expect(IslandActivity.microphoneOn(app: "Zoom").caption == nil)
    }

    @Test func namesTheAccountForLimitMoments() {
        #expect(IslandActivity.limitReset(.claude, account: "work@example.com").caption == "work@example.com")
        #expect(IslandActivity.limitWaiting(.codex, account: "me@example.com", resetsAt: Date()).caption == "me@example.com")
        #expect(IslandActivity.limitForecast(.claude, account: "work@example.com", runsOutAt: Date()).caption == "work@example.com")
    }

    @Test func skipsBlankTitles() {
        #expect(IslandActivity.nowPlaying(title: "  ", isPlaying: true).caption == nil)
        #expect(IslandActivity.agentDone(.claude, project: "").caption == nil)
    }
}

@Suite("Task times")
struct TaskTimeTests {
    let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-24 15:40 UTC, a Tuesday.
    let date = Date(timeIntervalSince1970: 1_795_534_800)

    @Test func followsA24HourClock() {
        let format = TaskTimeFormat(locale: Locale(identifier: "en_GB"), timeZone: utc)
        #expect(format.short(date, now: date) == "15:40")
        #expect(!format.text(date, now: date).contains("PM"))
        #expect(format.text(date, now: date).hasPrefix("15:40"))
    }

    @Test func followsA12HourClock() {
        let format = TaskTimeFormat(locale: Locale(identifier: "en_US"), timeZone: utc)
        let short = format.short(date, now: date)
        #expect(short.contains("3:40"))
        #expect(short.contains("PM"))
    }

    @Test func namesTheDayWhenItIsNotToday() {
        let format = TaskTimeFormat(locale: Locale(identifier: "en_GB"), timeZone: utc)
        let tomorrow = date.addingTimeInterval(-86_400)
        #expect(format.short(date, now: tomorrow).hasPrefix("Tue"))
        #expect(format.text(date, now: tomorrow).contains("Nov"))
    }

    @Test func keepsTheSameAnswerFromItsCache() {
        let format = TaskTimeFormat(locale: Locale(identifier: "en_GB"), timeZone: utc)
        let first = format.text(date, now: date)
        #expect(format.text(date, now: date) == first)
        format.reset()
        #expect(format.text(date, now: date) == first)
    }
}

@Suite("Diagnostics")
struct DiagnosticsTests {
    @Test func tellsWhoseLoopItIs() {
        #expect(AutoLoopOwner.of(parent: 812, ownPID: 812, marked: true) == .liveIsland)
        #expect(AutoLoopOwner.of(parent: 1, ownPID: 812, marked: true) == .leftOver)
        #expect(AutoLoopOwner.of(parent: 4410, ownPID: 812, marked: false) == .someoneElse)
    }

    @Test func findsTheFoldersThePathLacks() {
        let report = PathReport(path: "/usr/bin:/bin:/opt/homebrew/bin/:/usr/bin",
                                expected: ["/Users/example/.local/bin", "/opt/homebrew/bin"])
        #expect(report.folders == ["/usr/bin", "/bin", "/opt/homebrew/bin/"])
        #expect(report.missing == ["/Users/example/.local/bin"])
    }

    @Test func missesNothingWhenEverythingIsThere() {
        let report = PathReport(path: "/Users/example/.local/bin:/usr/bin", expected: ["/Users/example/.local/bin"])
        #expect(report.missing.isEmpty)
    }
}
