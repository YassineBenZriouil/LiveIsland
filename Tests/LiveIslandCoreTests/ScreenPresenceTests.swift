import Testing
@testable import LiveIslandCore

@Suite("Screen presence")
struct ScreenPresenceTests {
    @Test func startsOnScreen() {
        #expect(!ScreenPresence().isAway)
        #expect(ScreenPresence(screenLocked: true).isAway)
    }

    /// Applies events in order and returns which of them changed `isAway`.
    private func changes(_ presence: inout ScreenPresence, _ events: ScreenPresence.Event...) -> [Bool] {
        events.map { presence.apply($0) }
    }

    @Test func eachCauseKeepsItAway() {
        for (away, back) in [(ScreenPresence.Event.systemWillSleep, ScreenPresence.Event.systemDidWake),
                             (.displaysDidSleep, .displaysDidWake), (.screenLocked, .screenUnlocked),
                             (.sessionResigned, .sessionActivated)] {
            var presence = ScreenPresence()
            #expect(changes(&presence, away) == [true])
            #expect(presence.isAway)
            #expect(changes(&presence, back) == [true])
            #expect(!presence.isAway)
        }
    }

    @Test func displaysWakingBehindTheLockStayAway() {
        var presence = ScreenPresence()
        #expect(changes(&presence, .screenLocked, .displaysDidSleep, .displaysDidWake) == [true, false, false])
        #expect(presence.isAway)
        #expect(changes(&presence, .screenUnlocked) == [true])
        #expect(!presence.isAway)
    }

    @Test func aLitDisplayMeansTheMacIsAwake() {
        // The wake notice can be missed; the island must not stay paused forever.
        var presence = ScreenPresence()
        _ = changes(&presence, .systemWillSleep, .displaysDidSleep)
        #expect(presence.isAsleep)
        _ = changes(&presence, .displaysDidWake)
        #expect(!presence.isAsleep)
        #expect(!presence.isAway)
    }

    @Test func repeatedNoticesChangeNothing() {
        var presence = ScreenPresence()
        #expect(changes(&presence, .screenLocked, .screenLocked, .displaysDidSleep) == [true, false, false])
    }
}

@Suite("Waveform tap rebuild")
struct TapRebuildTests {
    @Test func aCallCodecRebuilds() {
        #expect(TapRebuild.isNeeded(builtAt: 48_000, nowAt: 16_000, isAlive: true))
        #expect(TapRebuild.isNeeded(builtAt: 44_100, nowAt: 48_000, isAlive: true))
    }

    @Test func theSameRateKeepsTheTap() {
        #expect(!TapRebuild.isNeeded(builtAt: 48_000, nowAt: 48_000, isAlive: true))
        #expect(!TapRebuild.isNeeded(builtAt: 48_000, nowAt: 48_000.2, isAlive: true))
        #expect(!TapRebuild.isNeeded(builtAt: 48_000, nowAt: nil, isAlive: true))
        #expect(!TapRebuild.isNeeded(builtAt: 48_000, nowAt: 0, isAlive: true))
    }

    @Test func aDeviceThatWentAwayRebuilds() {
        #expect(TapRebuild.isNeeded(builtAt: 48_000, nowAt: 48_000, isAlive: false))
    }
}
