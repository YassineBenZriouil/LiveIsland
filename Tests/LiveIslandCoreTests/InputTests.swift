import Testing
@testable import LiveIslandCore

@Suite("Keyboard shortcut")
struct HotKeyShortcutTests {
    @Test func theStandardShortcutReadsLikeAMenu() {
        #expect(HotKeyShortcut.standard.display == "⌃⌥⌘Space")
        #expect(HotKeyShortcut.standard.isUsable)
    }

    @Test func modifiersAreWrittenInApplesOrder() {
        let shortcut = HotKeyShortcut(keyCode: 34, modifiers: [.command, .shift, .option, .control], key: "I")
        #expect(shortcut.display == "⌃⌥⇧⌘I")
    }

    @Test func survivesSavingAndReading() {
        let shortcut = HotKeyShortcut(keyCode: 34, modifiers: [.control, .option], key: "I")
        #expect(HotKeyShortcut(saved: shortcut.saved) == shortcut)
    }

    @Test func readsTheCompactSavedForm() {
        let saved = #"{"key":"L","keyCode":37,"modifiers":9}"#
        #expect(HotKeyShortcut(saved: saved) == HotKeyShortcut(keyCode: 37, modifiers: [.control, .command], key: "L"))
    }

    @Test func nothingSavedOrSomethingBrokenFallsBack() {
        #expect(HotKeyShortcut(saved: nil) == nil)
        #expect(HotKeyShortcut(saved: "") == nil)
        #expect(HotKeyShortcut(saved: #"{"key":"L""#) == nil)
        // A shortcut that would take a letter away from typing is never read back.
        #expect(HotKeyShortcut(saved: #"{"key":"L","keyCode":37,"modifiers":4}"#) == nil)
    }

    @Test func aLetterNeedsCommandControlOrOption() {
        #expect(!HotKeyShortcut(keyCode: 37, modifiers: [], key: "L").isUsable)
        #expect(!HotKeyShortcut(keyCode: 37, modifiers: [.shift], key: "L").isUsable)
        #expect(HotKeyShortcut(keyCode: 37, modifiers: [.option], key: "L").isUsable)
    }

    @Test func functionKeysCanStandAlone() {
        #expect(HotKeyShortcut(keyCode: 105, modifiers: [], key: "F13").isUsable)
        #expect(HotKeyShortcut.keyName(forKeyCode: 105) == "F13")
    }

    @Test func keysWithoutACharacterHaveNames() {
        #expect(HotKeyShortcut.keyName(forKeyCode: 49) == "Space")
        #expect(HotKeyShortcut.keyName(forKeyCode: 126) == "↑")
        #expect(HotKeyShortcut.keyName(forKeyCode: 34) == nil)
    }
}

@Suite("Shortcut presses")
struct ShortcutPressTests {
    let tabs = ["Media", "Agents", "Activity", "Accounts"]

    @Test func theFirstPressOpens() {
        #expect(ShortcutPress.step(isOpen: false, current: "Accounts", tabs: tabs) == .open)
    }

    @Test func eachPressShowsTheNextTab() {
        #expect(ShortcutPress.step(isOpen: true, current: "Media", tabs: tabs) == .show("Agents"))
        #expect(ShortcutPress.step(isOpen: true, current: "Activity", tabs: tabs) == .show("Accounts"))
    }

    @Test func afterTheLastTabItCloses() {
        #expect(ShortcutPress.step(isOpen: true, current: "Accounts", tabs: tabs) == .close)
    }

    @Test func anUnknownTabGoesToTheFirst() {
        #expect(ShortcutPress.step(isOpen: true, current: "Gone", tabs: tabs) == .show("Media"))
        #expect(ShortcutPress.step(isOpen: true, current: "Gone", tabs: [String]()) == .close)
    }
}

@Suite("Scrolling a timer")
struct TimerLengthTests {
    @Test func stepsByTheMinuteWhileShort() {
        #expect(TimerLength.step(5, by: 1) == 6)
        #expect(TimerLength.step(5, by: -1) == 4)
        #expect(TimerLength.step(10, by: 1) == 15)
        #expect(TimerLength.step(60, by: 1) == 75)
        #expect(TimerLength.step(180, by: 1) == 210)
    }

    @Test func aLengthBetweenRungsMovesToTheNextOne() {
        #expect(TimerLength.step(7.5, by: 1) == 8)
        #expect(TimerLength.step(7.5, by: -1) == 7)
        #expect(TimerLength.step(12, by: 2) == 20)
    }

    @Test func staysBetweenAMinuteAndADay() {
        #expect(TimerLength.step(1, by: -3) == 1)
        #expect(TimerLength.step(1_440, by: 5) == 1_440)
        #expect(TimerLength.ladder.first == 1)
        #expect(TimerLength.ladder.last == LinkValue.longestTimerMinutes)
        #expect(TimerLength.step(.infinity, by: 1) == TimerLength.initial)
    }

    @Test func labelsReadPlainly() {
        #expect(TimerLength.label(45) == "45 min")
        #expect(TimerLength.label(60) == "1 h")
        #expect(TimerLength.label(90) == "1 h 30 min")
        #expect(TimerLength.label(1_440) == "24 h")
    }

    @Test func aTrackpadAddsUpSmallDeltas() {
        var steps = ScrollSteps()
        #expect(steps.add(5, precise: true) == 0)
        #expect(steps.add(5, precise: true) == 0)
        #expect(steps.add(5, precise: true) == 1)
    }

    @Test func aWheelStepsOncePerNotch() {
        var steps = ScrollSteps()
        #expect(steps.add(1, precise: false) == 1)
        #expect(steps.add(-1, precise: false) == -1)
    }

    @Test func turningAroundStartsAfresh() {
        var steps = ScrollSteps()
        #expect(steps.add(10, precise: true) == 0)
        #expect(steps.add(-14, precise: true) == -1)
    }

    @Test func aFastFlickIsCapped() {
        var steps = ScrollSteps()
        #expect(steps.add(500, precise: true) == ScrollSteps.maxPerEvent)
        #expect(steps.add(.nan, precise: true) == 0)
    }
}
