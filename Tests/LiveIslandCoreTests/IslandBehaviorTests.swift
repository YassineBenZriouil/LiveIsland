import CoreGraphics
import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Placing with ⌘")
struct CommandTapTests {
    /// Feeds polls of (⌘ down, other keys down) and returns which ones set the island down.
    func run(_ start: Bool, _ polls: [(Bool, Bool)]) -> [Bool] {
        var tap = CommandTap(commandDown: start)
        return polls.map { tap.update(commandDown: $0.0, otherKeysDown: $0.1) }
    }

    @Test func aLonePressPlacesWhenLetGo() {
        #expect(run(false, [(false, false), (true, false), (true, false), (false, false)]) == [false, false, false, true])
    }

    @Test func aShortcutDoesNot() {
        // ⌘C: C goes down while ⌘ is held.
        #expect(run(false, [(true, false), (true, true), (true, false), (false, false)]) == [false, false, false, false])
        // ⌘ pressed with C already down.
        #expect(run(false, [(true, true), (false, false)]) == [false, false])
        // The next lone press still works.
        #expect(run(false, [(true, true), (false, false), (true, false), (false, false)]) == [false, false, false, true])
    }

    @Test func aCommandHeldAtTheStartHasToBeLetGoFirst() {
        #expect(run(true, [(true, false), (false, false)]) == [false, false])
        #expect(run(true, [(true, false), (false, false), (true, false), (false, false)]) == [false, false, false, true])
    }

    @Test func anAppSwitchDuringThePressIsAShortcut() {
        var tap = CommandTap(commandDown: false)
        var placed = [tap.update(commandDown: true, otherKeysDown: false)]
        tap.noteShortcut()
        placed.append(tap.update(commandDown: false, otherKeysDown: false))
        // Noted while ⌘ is up, it doesn't spoil the next press.
        tap.noteShortcut()
        placed.append(tap.update(commandDown: true, otherKeysDown: false))
        placed.append(tap.update(commandDown: false, otherKeysDown: false))
        #expect(placed == [false, false, false, true])
    }
}

@Suite("Full screen and screen sharing")
struct ScreenStateTests {
    /// The built-in display and one to its right, in window-list coordinates (top-left origin).
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)

    func window(_ owner: String, pid: Int32 = 900, layer: Int = 0, _ bounds: CGRect) -> ScreenWindow {
        ScreenWindow(ownerPID: pid, ownerName: owner, layer: layer, bounds: bounds)
    }

    @Test func readsTheWindowList() {
        let info: [String: Any] = [
            "kCGWindowOwnerPID": NSNumber(value: 412), "kCGWindowOwnerName": "Safari", "kCGWindowLayer": NSNumber(value: 0),
            "kCGWindowBounds": ["X": NSNumber(value: 0), "Y": NSNumber(value: 0), "Width": NSNumber(value: 1512), "Height": NSNumber(value: 982)],
        ]
        #expect(ScreenWindow(info: info) == window("Safari", pid: 412, builtIn))
        #expect(ScreenWindow(info: ["kCGWindowOwnerName": "Safari"]) == nil)
    }

    @Test func aWindowCoveringTheDisplayIsFullScreen() {
        #expect(FullScreen.covers(builtIn, windows: [window("Safari", builtIn)], ignoring: 1))
        #expect(FullScreen.covers(external, windows: [window("TV", external)], ignoring: 1))
        // Only on its own display.
        #expect(!FullScreen.covers(builtIn, windows: [window("TV", external)], ignoring: 1))
    }

    @Test func aZoomedWindowTheDesktopAndOurOwnPanelAreNot() {
        let zoomed = CGRect(x: 0, y: 37, width: 1512, height: 945)
        #expect(!FullScreen.covers(builtIn, windows: [window("Safari", zoomed)], ignoring: 1))
        #expect(!FullScreen.covers(builtIn, windows: [window("Dock", layer: -2147483624, builtIn)], ignoring: 1))
        #expect(!FullScreen.covers(builtIn, windows: [window("Finder", pid: 1, builtIn)], ignoring: 1))
    }

    @Test func seesCaptureTools() {
        let menuBar = window("Window Server", layer: 24, CGRect(x: 0, y: 0, width: 1512, height: 37))
        #expect(!ScreenSharing.isSharing(windows: [menuBar], runningApps: ["com.apple.Safari"]))
        #expect(ScreenSharing.isSharing(windows: [menuBar, window("screencaptureui", layer: 25, builtIn)], runningApps: []))
        #expect(ScreenSharing.isSharing(windows: [window("CptHost", CGRect(x: 0, y: 0, width: 300, height: 40))], runningApps: []))
        #expect(ScreenSharing.isSharing(windows: [], runningApps: ["com.obsproject.obs-studio"]))
    }

    @Test func callsAndTimersStayOverFullScreen() {
        #expect(IslandActivity.call(app: "FaceTime", since: Date()).showsOverFullScreen)
        #expect(IslandActivity.timer(endsAt: Date()).showsOverFullScreen)
        #expect(IslandActivity.timerFinished.showsOverFullScreen)
        #expect(!IslandActivity.nowPlaying(title: "Song", isPlaying: true).showsOverFullScreen)
        #expect(!IslandActivity.agentNeedsYou(.claude, project: "app").showsOverFullScreen)
    }
}

@Suite("Top edge without a notch")
struct TopEdgeHotSpotTests {
    let area = CGRect(x: 656, y: 976, width: 200, height: 6)

    @Test func onlyThePointerPushedAgainstTheTopCounts() {
        #expect(TopEdgeHotSpot.contains(CGPoint(x: 756, y: 981), area: area, screenTop: 982))
        #expect(TopEdgeHotSpot.contains(CGPoint(x: 656, y: 982), area: area, screenTop: 982))
        // In the menu bar, a little lower: that's someone clicking a menu.
        #expect(!TopEdgeHotSpot.contains(CGPoint(x: 756, y: 970), area: area, screenTop: 982))
        #expect(!TopEdgeHotSpot.contains(CGPoint(x: 600, y: 982), area: area, screenTop: 982))
    }
}
