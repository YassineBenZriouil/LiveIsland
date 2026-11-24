import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Clock ticks")
struct ClockTicksTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var last: Date { now.addingTimeInterval(-ClockTicks.interval) }

    func needed(timer: Bool = false, call: Bool = false, limit: Bool = false, events: [TimeInterval] = []) -> Bool {
        ClockTicks.needed(since: last, now: now, timerRunning: timer, inCall: call, limitShown: limit,
                          eventStarts: events.map { now.addingTimeInterval($0) })
    }

    @Test func staysStillWithNothingTimeBased() {
        #expect(!needed())
    }

    @Test func ticksForATimerACallOrALimit() {
        #expect(needed(timer: true))
        #expect(needed(call: true))
        #expect(needed(limit: true))
    }

    @Test func ticksOnlyNearAnEvent() {
        #expect(!needed(events: [3600]))          // in an hour: nothing yet
        #expect(needed(events: [590]))            // just came into view
        #expect(needed(events: [-60]))            // started a minute ago, still showing
        #expect(needed(events: [-130]))           // just went: one more bump hides it
        #expect(!needed(events: [-600]))          // long gone
    }

    @Test func soonMatchesTheWindow() {
        #expect(ClockTicks.isSoon(now.addingTimeInterval(599), at: now))
        #expect(!ClockTicks.isSoon(now.addingTimeInterval(600), at: now))
        #expect(ClockTicks.isSoon(now.addingTimeInterval(-119), at: now))
        #expect(!ClockTicks.isSoon(now.addingTimeInterval(-120), at: now))
    }
}

@Suite("Lookup cache")
struct LookupCacheTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func remembersHitsAndMisses() {
        var cache = LookupCache<String, String>(hitLifetime: 3600, missLifetime: 600)
        var asked = 0
        let lookup: (String) -> String? = { asked += 1; return $0 == "com.apple.Music" ? "/System/Applications/Music.app" : nil }
        for _ in 0..<3 {
            #expect(cache.value(for: "com.apple.Music", at: start, lookup: lookup) == "/System/Applications/Music.app")
            #expect(cache.value(for: "com.spotify.client", at: start, lookup: lookup) == nil)
        }
        #expect(asked == 2)
    }

    @Test func missesExpireBeforeHits() {
        var cache = LookupCache<String, String>(hitLifetime: 3600, missLifetime: 600)
        var installed = false
        var asked = 0
        let lookup: (String) -> String? = { asked += 1; return installed || $0 == "a" ? "/Applications/\($0).app" : nil }
        _ = cache.value(for: "a", at: start, lookup: lookup)
        _ = cache.value(for: "b", at: start, lookup: lookup)
        installed = true
        let later = start.addingTimeInterval(601)
        #expect(cache.value(for: "b", at: later, lookup: lookup) == "/Applications/b.app")
        _ = cache.value(for: "a", at: later, lookup: lookup)
        #expect(asked == 3)
    }

    @Test func forgettingMissesKeepsHits() {
        var cache = LookupCache<String, String>(hitLifetime: 3600, missLifetime: 600)
        var asked = 0
        let lookup: (String) -> String? = { asked += 1; return $0 == "a" ? "/Applications/a.app" : nil }
        _ = cache.value(for: "a", at: start, lookup: lookup)
        _ = cache.value(for: "b", at: start, lookup: lookup)
        cache.forgetMisses()
        _ = cache.value(for: "a", at: start, lookup: lookup)
        _ = cache.value(for: "b", at: start, lookup: lookup)
        #expect(asked == 3)
    }
}
