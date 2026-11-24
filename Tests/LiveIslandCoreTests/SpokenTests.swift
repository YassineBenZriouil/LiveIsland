import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Counted phrases")
struct PluralTests {
    @Test func picksTheWholePhraseForOneOrMore() {
        #expect(Spoken.plural(1, one: "1 agent needs you", other: "1 agents need you") == "1 agent needs you")
        #expect(Spoken.plural(3, one: "3 agent needs you", other: "3 agents need you") == "3 agents need you")
        #expect(Spoken.plural(0, one: "one", other: "none") == "none")
    }

    @Test func countsANoun() {
        #expect(Spoken.count(1, "account", "accounts") == "1 account")
        #expect(Spoken.count(2, "account", "accounts") == "2 accounts")
        #expect(Spoken.count(0, "account", "accounts") == "0 accounts")
        #expect(Spoken.count(1, "login copy", "login copies") == "1 login copy")
        #expect(Spoken.count(4, "login copy", "login copies") == "4 login copies")
    }
}

@Suite("Spoken words")
struct SpokenWordsTests {
    @Test func spellsOutDurations() {
        #expect(Spoken.duration(1) == "1 second")
        #expect(Spoken.duration(45) == "45 seconds")
        #expect(Spoken.duration(60) == "1 minute")
        #expect(Spoken.duration(90) == "1 minute 30 seconds")
        #expect(Spoken.duration(12 * 60 + 20) == "12 minutes")
        #expect(Spoken.duration(3600) == "1 hour")
        #expect(Spoken.duration(3600 + 5 * 60) == "1 hour 5 minutes")
        #expect(Spoken.duration(2 * 86_400 + 4 * 3600) == "2 days 4 hours")
        #expect(Spoken.duration(86_400) == "1 day")
    }

    @Test func neverGoesNegativeOrBreaksOnBadInput() {
        #expect(Spoken.duration(-30) == "0 seconds")
        #expect(Spoken.duration(.nan) == "0 seconds")
        #expect(Spoken.percent(.infinity) == "0%")
    }

    @Test func readsASliderAsAPercentage() {
        #expect(Spoken.percent(0.454) == "45%")
        #expect(Spoken.percent(1.4) == "100%")
        #expect(Spoken.percent(-0.2) == "0%")
    }

    @Test func stepsAnAdjustableSliderWithinItsRange() {
        #expect(abs(Spoken.stepped(0.5, up: true) - 0.55) < 1e-9)
        #expect(abs(Spoken.stepped(0.5, up: false) - 0.45) < 1e-9)
        #expect(Spoken.stepped(0.98, up: true) == 1)
        #expect(Spoken.stepped(0.02, up: false) == 0)
        #expect(abs(Spoken.stepped(0.2, up: true, step: 0.1) - 0.3) < 1e-9)
    }
}

@Suite("Closed island for VoiceOver")
struct SpokenIslandTests {
    let now = Date(timeIntervalSince1970: 1_795_534_800)

    @Test func readsAWorkingAgentWithItsProjectAndTime() {
        let activity = IslandActivity.agentWorking(.claude, project: "LiveIsland", since: now.addingTimeInterval(-180))
        #expect(activity.spokenLabel(now: now) == "Claude Code working on LiveIsland, 3 minutes")
        #expect(activity.spokenLabel(now: now, hidingDetails: true) == "Claude Code working, 3 minutes")
    }

    @Test func saysWhatAnAgentWaitsOn() {
        let activity = IslandActivity.agentNeedsYou(.codex, project: "api")
        let bash = AgentRequest(kind: .permission, tool: "Bash", summary: "npm test")
        #expect(activity.spokenLabel(now: now, request: bash) == "Codex asks to use Bash in api")
        #expect(activity.spokenLabel(now: now, request: bash, hidingDetails: true) == "Codex needs you")
        #expect(activity.spokenLabel(now: now, request: AgentRequest(kind: .question)) == "Codex has a question in api")
        #expect(activity.spokenLabel(now: now) == "Codex needs you in api")
    }

    @Test func tellsAFinishedTurnFromAQuestion() {
        let done = IslandActivity.agentDone(.claude, project: "web")
        #expect(done.spokenLabel(now: now) == "Claude Code is done in web")
        #expect(done.spokenLabel(now: now, request: AgentRequest(kind: .question)) == "Claude Code asks you something in web")
    }

    @Test func hidesAccountsAndTitlesWhileSharing() {
        let limit = IslandActivity.limitWaiting(.claude, account: "work@example.com", resetsAt: now.addingTimeInterval(2 * 3600))
        #expect(limit.spokenLabel(now: now) == "Claude Code is out of usage on work@example.com, back in 2 hours")
        #expect(limit.spokenLabel(now: now, hidingDetails: true) == "Claude Code is out of usage, back in 2 hours")
        let switched = IslandActivity.accountSwitched(to: "me@example.com")
        #expect(switched.spokenLabel(now: now) == "Switched accounts to me@example.com")
        #expect(switched.spokenLabel(now: now, hidingDetails: true) == "Switched accounts")
        let event = IslandActivity.eventSoon(title: "Standup", startsAt: now.addingTimeInterval(300))
        #expect(event.spokenLabel(now: now) == "Standup in 5 minutes")
        #expect(event.spokenLabel(now: now, hidingDetails: true) == "Event in 5 minutes")
        let song = IslandActivity.nowPlaying(title: "Teardrop", isPlaying: true)
        #expect(song.spokenLabel(now: now) == "Playing: Teardrop")
        #expect(song.spokenLabel(now: now, hidingDetails: true) == "Playing")
    }

    @Test func readsDevicesTimersAndCalls() {
        #expect(IslandActivity.timer(endsAt: now.addingTimeInterval(90)).spokenLabel(now: now) == "Timer, 1 minute 30 seconds left")
        #expect(IslandActivity.timerFinished.spokenLabel(now: now) == "Timer done")
        #expect(IslandActivity.call(app: "FaceTime", since: now.addingTimeInterval(-42)).spokenLabel(now: now) == "Call in FaceTime, 42 seconds")
        #expect(IslandActivity.headphonesConnected(name: "AirPods Pro", battery: 80).spokenLabel(now: now) == "AirPods Pro connected, battery 80%")
        #expect(IslandActivity.headphonesConnected(name: "AirPods", battery: nil).spokenLabel(now: now) == "AirPods connected")
        #expect(IslandActivity.lowBattery(device: nil, percent: 15).spokenLabel(now: now) == "Mac battery low, 15%")
        #expect(IslandActivity.cameraOn(app: nil).spokenLabel(now: now) == "Camera in use")
        #expect(IslandActivity.microphoneOn(app: "Zoom").spokenLabel(now: now) == "Microphone in use by Zoom")
    }
}
