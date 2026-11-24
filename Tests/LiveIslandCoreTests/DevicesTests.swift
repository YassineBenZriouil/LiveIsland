import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Calls")
struct CallTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func aShortMicDropKeepsTheCallAndItsTimer() {
        var tracker = CallTracker()
        tracker.update(app: "FaceTime", at: start)
        let during = tracker.update(app: nil, at: start.addingTimeInterval(1))
        #expect(during?.app == "FaceTime")
        let back = tracker.update(app: "FaceTime", at: start.addingTimeInterval(2))
        #expect(back?.since == start)
    }

    @Test func theCallEndsAfterTheGracePeriod() {
        var tracker = CallTracker()
        tracker.update(app: "Zoom", at: start)
        #expect(tracker.update(app: nil, at: start.addingTimeInterval(CallTracker.grace + 0.1)) == nil)
        let next = tracker.update(app: "Zoom", at: start.addingTimeInterval(10))
        #expect(next?.since == start.addingTimeInterval(10))
    }

    @Test func anotherAppStartsANewCall() {
        var tracker = CallTracker()
        tracker.update(app: "Zoom", at: start)
        let next = tracker.update(app: "FaceTime", at: start.addingTimeInterval(3))
        #expect(next?.app == "FaceTime")
        #expect(next?.since == start.addingTimeInterval(3))
    }

    @Test func asksToLookAgainWhenTheGracePeriodEnds() {
        var tracker = CallTracker()
        #expect(tracker.endCheck(after: start, micHeld: false) == nil)
        tracker.update(app: "Zoom", at: start)
        #expect(tracker.endCheck(after: start, micHeld: true) == nil)
        tracker.update(app: nil, at: start.addingTimeInterval(1))
        #expect(tracker.endCheck(after: start.addingTimeInterval(1), micHeld: false) == start.addingTimeInterval(CallTracker.grace))
    }
}

@Suite("Battery announcements")
struct BatteryAlertsTests {
    @Test func theLevelFoundAtLaunchIsntNews() {
        var alerts = BatteryAlerts()
        #expect(alerts.mac(percent: 15, onPower: false, isFull: false) == nil)
        var fresh = BatteryAlerts()
        #expect(fresh.mac(percent: 100, onPower: true, isFull: true) == nil)
    }

    @Test func saysTwentyAndTenOnceEachOnTheWayDown() {
        var alerts = BatteryAlerts()
        let readings = [23, 21, 20, 19, 20, 18, 11, 10, 9]
        let said = readings.compactMap { alerts.mac(percent: $0, onPower: false, isFull: false) }
        #expect(said == [.low(percent: 20), .low(percent: 10)])
    }

    @Test func aBigDropSaysOnlyTheLowestLevel() {
        var alerts = BatteryAlerts()
        _ = alerts.mac(percent: 30, onPower: false, isFull: false)
        #expect(alerts.mac(percent: 8, onPower: false, isFull: false) == .low(percent: 10))
    }

    @Test func nothingIsLowWhilePluggedIn() {
        var alerts = BatteryAlerts()
        _ = alerts.mac(percent: 22, onPower: true, isFull: false)
        #expect(alerts.mac(percent: 19, onPower: true, isFull: false) == nil)
    }

    @Test func fullyChargedOnceUntilItDrains() {
        var alerts = BatteryAlerts()
        _ = alerts.mac(percent: 98, onPower: true, isFull: false)
        #expect(alerts.mac(percent: 100, onPower: true, isFull: true) == .full)
        #expect(alerts.mac(percent: 100, onPower: true, isFull: true) == nil)
        _ = alerts.mac(percent: 96, onPower: false, isFull: false)
        _ = alerts.mac(percent: 97, onPower: true, isFull: false)
        #expect(alerts.mac(percent: 100, onPower: true, isFull: true) == .full)
    }

    @Test func headphonesGetTheirOwnLowLevels() {
        var alerts = BatteryAlerts()
        #expect(alerts.headphones("AirPods Pro", percent: 25) == nil)
        #expect(alerts.headphones("AirPods Pro", percent: nil) == nil)
        #expect(alerts.headphones("AirPods Pro", percent: 20) == 20)
        #expect(alerts.headphones("AirPods Pro", percent: 15) == nil)
        #expect(alerts.headphones("Beats", percent: 10) == nil)
        #expect(alerts.headphones("AirPods Pro", percent: 10) == 10)
    }

    @Test func reconnectedHeadphonesStartOver() {
        var alerts = BatteryAlerts()
        _ = alerts.headphones("AirPods", percent: 40)
        alerts.forgetHeadphones("AirPods")
        #expect(alerts.headphones("AirPods", percent: 12) == nil)
    }
}

@Suite("Helper processes")
struct HelperAppsTests {
    private let running = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.google.Chrome.canary"]

    @Test func aBrowserHelperBelongsToItsBrowser() {
        #expect(HelperApps.owner(of: "com.google.Chrome.helper", among: running) == "com.google.Chrome")
        #expect(HelperApps.owner(of: "com.microsoft.edgemac.helper.renderer", among: running) == "com.microsoft.edgemac")
    }

    @Test func theLongestMatchWins() {
        #expect(HelperApps.owner(of: "com.google.Chrome.canary.helper", among: running) == "com.google.Chrome.canary")
    }

    @Test func onlyWholeNamePartsMatch() {
        #expect(HelperApps.owner(of: "com.google.ChromeRemoteDesktop", among: running) == nil)
        #expect(HelperApps.owner(of: "com.google.Chrome", among: running) == nil)
        #expect(HelperApps.owner(of: "com.apple.WebKit.GPU", among: running) == nil)
    }
}

@Suite("Headphone battery")
struct HeadphoneBatteryTests {
    /// Shaped like `system_profiler SPBluetoothDataType -json` (example devices).
    private let report = Data(#"{"SPBluetoothDataType":[{"controller_properties":{"controller_state":"attrib_on"},"device_connected":[{"Example AirPods Pro":{"device_address":"00:11:22:33:44:55","device_batteryLevelCase":"64%","device_batteryLevelLeft":"18%","device_batteryLevelRight":"22%","device_minorType":"Headphones"}},{"Example Speaker":{"device_address":"66:77:88:99:AA:BB","device_batteryLevelMain":"80%","device_minorType":"Speaker"}}],"device_not_connected":[{"Old Headphones":{"device_address":"CC:DD:EE:FF:00:11"}}]}]}"#.utf8)

    @Test func readsEachEarbudAndTheCase() {
        let levels = HeadphoneBattery.parse(report, name: "Example AirPods Pro")
        #expect(levels == HeadphoneBattery(left: 18, right: 22, caseLevel: 64))
    }

    @Test func readsASingleBattery() {
        #expect(HeadphoneBattery.parse(report, name: "Example Speaker") == HeadphoneBattery(single: 80))
    }

    @Test func aDeviceNotConnectedIsntRead() {
        #expect(HeadphoneBattery.parse(report, name: "Old Headphones") == nil)
        #expect(HeadphoneBattery.parse(Data("not json".utf8), name: "Example Speaker") == nil)
    }
}

@Suite("Low battery activity")
struct LowBatteryActivityTests {
    @Test func lowBatteryBeatsAgentsButNotACall() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let low = IslandActivity.lowBattery(device: nil, percent: 10)
        #expect(IslandActivity.mostImportant([.agentDone(.claude, project: "app"), low]) == low)
        #expect(IslandActivity.mostImportant([low, .call(app: "FaceTime", since: now)]) == .call(app: "FaceTime", since: now))
    }
}
