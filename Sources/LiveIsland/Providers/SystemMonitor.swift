import AppKit
import CoreBluetooth
import CoreAudio
import CoreMediaIO
import Darwin
import IOBluetooth
import IOKit.ps
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "system")

/// Calls, microphone, camera, battery and headphones.
///
/// Nothing here polls: Core Audio and CoreMediaIO say when a device starts or stops recording,
/// IOKit when the power source changes, and IOBluetooth when headphones come and go.
@MainActor
final class SystemMonitor: NSObject {
    struct Snapshot: Equatable {
        /// Apps using the microphone right now (display names).
        var microphoneApps: [String] = []
        var cameraOn = false
        /// The calling app holding the microphone, and since when.
        var call: (app: String, since: Date)?
        var battery: Battery?
        var headphones: Headphones?

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.microphoneApps == rhs.microphoneApps && lhs.cameraOn == rhs.cameraOn
                && lhs.call?.app == rhs.call?.app && lhs.call?.since == rhs.call?.since
                && lhs.battery == rhs.battery && lhs.headphones == rhs.headphones
        }
    }

    struct Battery: Equatable {
        var percent: Int
        var isCharging: Bool
        var onPower: Bool
        /// Until empty on battery, or until full while charging; nil while macOS estimates.
        var minutesRemaining: Int? = nil
    }

    struct Headphones: Equatable {
        var name: String
        var left: Int?
        var right: Int?
        var single: Int?
        var caseLevel: Int?
        var connected: Bool

        /// The lowest earbud level, for a single number in the notch.
        var summary: Int? { [left, right, single].compactMap { $0 }.min() }
    }

    var onUpdate: ((Snapshot) -> Void)?
    /// Fires when power is plugged in, the battery gets low or full, and headphones connect or get low.
    var onEvent: ((IslandActivity) -> Void)?
    private(set) var snapshot = Snapshot()

    private let audio = AudioWatch()
    private let camera = CameraWatch()
    private var refreshPending = false
    /// A slow look now and then, in case a listener was missed (a device that never reported).
    private var safetyNet: Timer?
    /// Ends a call whose mic stayed gone past the grace period.
    private var callEnd: Timer?
    private var calls = CallTracker()
    private var alerts = BatteryAlerts()
    /// Headphones report their battery only when asked, so ask again while they're connected.
    private var headphoneRefresh: Timer?
    private static let headphoneRefreshInterval: TimeInterval = 5 * 60

    private var powerSource: CFRunLoopSource?
    private var connectNotification: IOBluetoothUserNotification?
    /// One per connected device, by address; each is dropped once it fires.
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var startedAt = Date()
    private let bluetooth = BluetoothAccess()
    /// When each device was last announced; macOS can report one connection several times.
    private var announced: [String: Date] = [:]
    /// Display names by bundle identifier: Launch Services is slow to ask on every change.
    private static var names: [String: String] = [:]
    /// The app each audio process belongs to, by process ID, until the process list changes.
    private var owners: [pid_t: String] = [:]

    /// Apps whose microphone use means a call.
    private static let callApps: Set<String> = [
        "com.apple.FaceTime", "com.apple.TelephonyUtilities", "com.apple.avconferenced", "us.zoom.xos",
        "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "com.tinyspeck.slackmacgap", "com.skype.skype", "ru.keepcoder.Telegram", "com.cisco.webexmeetingsapp",
    ]
    /// Always-listening system services and audio tools, not someone using the mic.
    private static let ignoredMicrophoneClients: [String] = [
        "com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.siri", "com.apple.assistant",
        "com.apple.accessibility", "com.apple.SpeechRecognitionCore", "com.aissam.",
    ]
    /// The waveform's private aggregate device (see `AudioLevelMeter`): it runs while music
    /// plays, and isn't anyone using the microphone.
    private static let ownDevicePrefix = "com.aissam.liveisland."

    func start() {
        startedAt = Date()
        audio.onChange = { [weak self] in self?.scheduleRefresh() }
        camera.onChange = { [weak self] in self?.scheduleRefresh() }
        refreshDevices()
        safetyNet = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
        safetyNet?.tolerance = 10
        startPowerMonitoring()
        watchWorkspace()
        bluetooth.whenGranted { [weak self] in self?.startWatchingHeadphones() }
    }

    /// Only once Bluetooth access is granted: before that, IOBluetooth's first call waits for
    /// the user's answer to the permission prompt, freezing the whole app.
    private func startWatchingHeadphones() {
        guard connectNotification == nil else { return }
        // Devices already connected get reported as they're registered; those aren't news.
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() && Self.isAudio(device) {
            watchDisconnect(of: device)
            Task { await readHeadphoneBattery(name: device.name ?? "Headphones", announce: false) }
        }
    }

    func stop() {
        safetyNet?.invalidate()
        callEnd?.invalidate()
        headphoneRefresh?.invalidate()
        audio.removeAll()
        camera.removeAll()
        connectNotification?.unregister()
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    /// A permission granted in System Settings shows up when the user comes back from there,
    /// and a Mac waking from sleep has news about its battery and headphones.
    private func watchWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bluetooth.recheck() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
    }

    private func didWake() {
        bluetooth.recheck()
        readBattery(announce: true)
        scheduleRefresh()
        if let headphones = snapshot.headphones, headphones.connected {
            Task { await readHeadphoneBattery(name: headphones.name, announce: false) }
        }
    }

    // MARK: - Microphone, camera, calls

    /// Several properties change together when an app starts recording; look once for all of them.
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            self.refreshDevices()
        }
    }

    private func refreshDevices() {
        let devices = AudioProps.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices)
        let processes = AudioProps.ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        let inputs = devices.filter { AudioProps.hasInput($0) && !Self.isOwnDevice($0) }
        if audio.watch(inputs: inputs, processes: processes) { owners.removeAll() }
        let cameras = CameraWatch.devices()
        camera.watch(cameras)

        let now = Date()
        var next = snapshot
        let clients = anyInputRunning(inputs) ? microphoneClients(processes) : []
        let callClient = clients.first { Self.callApps.contains($0) }
        next.microphoneApps = clients.filter { $0 != callClient }.map(Self.displayName(of:))
        next.cameraOn = cameras.contains(where: CameraWatch.isRunning)
        next.call = calls.update(app: callClient.map(Self.displayName(of:)), at: now)
        scheduleCallEnd(now: now, micHeld: callClient != nil)
        publish(next)
    }

    /// Nothing else changes when a calling app lets go of the mic, so look again once the grace
    /// period is over.
    private func scheduleCallEnd(now: Date, micHeld: Bool) {
        callEnd?.invalidate()
        callEnd = nil
        guard let at = calls.endCheck(after: now, micHeld: micHeld) else { return }
        callEnd = Timer.scheduledTimer(withTimeInterval: at.timeIntervalSince(now) + 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
    }

    private static func isOwnDevice(_ device: AudioObjectID) -> Bool {
        AudioProps.string(device, kAudioDevicePropertyDeviceUID)?.hasPrefix(ownDevicePrefix) == true
    }

    /// Whether any device that records is running at all: one cheap question that saves
    /// asking every audio process.
    private func anyInputRunning(_ inputs: [AudioObjectID]) -> Bool {
        inputs.contains { AudioProps.uint32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0 != 0 }
    }

    /// The apps recording right now, by bundle identifier, each helper counted as its app.
    private func microphoneClients(_ processes: [AudioObjectID]) -> [String] {
        var clients: [String] = []
        for process in processes where AudioProps.uint32(process, kAudioProcessPropertyIsRunningInput) ?? 0 != 0 {
            let identifier = AudioProps.string(process, kAudioProcessPropertyBundleID)
            let pid = AudioProps.pid(process)
            guard !Self.isIgnored(identifier) else { continue }
            let owner = pid.map { pid in owners[pid] ?? resolveOwner(pid: pid, bundleID: identifier) } ?? identifier
            if let pid, let owner { owners[pid] = owner }
            guard let owner, !owner.isEmpty, !Self.isIgnored(owner), !clients.contains(owner) else { continue }
            clients.append(owner)
        }
        return clients
    }

    private static func isIgnored(_ identifier: String?) -> Bool {
        guard let identifier else { return false }
        return ignoredMicrophoneClients.contains { identifier.hasPrefix($0) }
    }

    /// The regular app behind a recording process, so a browser call reads "Google Chrome",
    /// not "GPU" or "Google Chrome Helper". Asks macOS which app is responsible for the process,
    /// then walks up its parents, then matches the bundle identifier against running apps.
    private func resolveOwner(pid: pid_t, bundleID: String?) -> String? {
        if let id = Self.regularApp(pid) { return id }
        if let responsible = ProcessOwner.responsible(for: pid), responsible != pid, let id = Self.regularApp(responsible) { return id }
        var current = pid
        for _ in 0..<4 {
            guard let parent = ProcessOwner.parent(of: current), parent > 1 else { break }
            if let id = Self.regularApp(parent) { return id }
            current = parent
        }
        if let bundleID {
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier)
            if let owner = HelperApps.owner(of: bundleID, among: running) { return owner }
        }
        return bundleID
    }

    private static func regularApp(_ pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return nil }
        return app.bundleIdentifier
    }

    static func displayName(of bundleIdentifier: String) -> String {
        if let cached = names[bundleIdentifier] { return cached }
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else {
            switch bundleIdentifier {
            case "com.apple.TelephonyUtilities", "com.apple.avconferenced": name = "iPhone Call"
            default: name = bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
            }
        }
        names[bundleIdentifier] = name
        return name
    }

    // MARK: - Battery

    private func startPowerMonitoring() {
        readBattery(announce: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.readBattery(announce: true) }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func readBattery(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            var battery = Battery(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            let minutes = description[battery.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            if let minutes, minutes > 0, battery.isCharging || !battery.onPower { battery.minutesRemaining = minutes }
            let isFull = battery.percent >= 100 || (description[kIOPSIsChargedKey] as? Bool ?? false)
            let alert = alerts.mac(percent: battery.percent, onPower: battery.onPower, isFull: isFull)
            let pluggedIn = announce && battery.onPower && snapshot.battery?.onPower == false
            var next = snapshot
            next.battery = battery
            publish(next)
            if pluggedIn {
                onEvent?(.charging(percent: battery.percent))
            } else if announce, let alert {
                switch alert {
                case .low: onEvent?(.lowBattery(device: nil, percent: battery.percent))
                case .full: onEvent?(.charging(percent: battery.percent))
                }
            }
            return
        }
    }

    // MARK: - Headphones

    @objc private func bluetoothConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isAudio(device) else { return }
        let name = device.name ?? "Headphones"
        watchDisconnect(of: device)
        // Devices already connected at launch are reported too; those aren't news.
        guard Date().timeIntervalSince(startedAt) > 8 else { return }
        let repeated = announced[name].map { Date().timeIntervalSince($0) < 15 } ?? false
        if !repeated { announced[name] = Date() }
        log.notice("Audio device connected: \(name, privacy: .public)")
        // Battery levels show up a moment after the connection.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await readHeadphoneBattery(name: name, announce: !repeated)
        }
    }

    @objc private func bluetoothDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // Each notification fires once; keeping it would pile up one per connection.
        notification.unregister()
        disconnectNotifications = disconnectNotifications.filter { $0.value !== notification }
        guard var headphones = snapshot.headphones, headphones.name == device.name else { return }
        alerts.forgetHeadphones(headphones.name)
        headphones.connected = false
        var next = snapshot
        next.headphones = headphones
        publish(next)
        stopHeadphoneRefresh()
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        let address = device.addressString ?? device.name ?? "?"
        guard disconnectNotifications[address] == nil,
              let notification = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:)))
        else { return }
        disconnectNotifications[address] = notification
    }

    /// Battery levels for AirPods and other headphones, from System Information's Bluetooth report.
    private func readHeadphoneBattery(name: String, announce: Bool) async {
        let report = try? await ProcessRunner.output("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        let levels = report.flatMap { HeadphoneBattery.parse($0, name: name) }
        let previous = snapshot.headphones?.name == name ? snapshot.headphones : nil
        // A later look that comes back empty keeps what the last one found.
        guard announce || levels != nil || previous == nil || previous?.connected == false else { return }
        var headphones = Headphones(name: name, connected: true)
        if let levels {
            headphones.left = levels.left
            headphones.right = levels.right
            headphones.single = levels.single
            headphones.caseLevel = levels.caseLevel
        }
        var next = snapshot
        next.headphones = headphones
        publish(next)
        startHeadphoneRefresh()
        let low = alerts.headphones(name, percent: headphones.summary)
        if announce {
            onEvent?(.headphonesConnected(name: name, battery: headphones.summary))
        } else if let low, let summary = headphones.summary {
            log.notice("Headphones low: \(low)%")
            onEvent?(.lowBattery(device: name, percent: summary))
        }
    }

    private func startHeadphoneRefresh() {
        guard headphoneRefresh == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.headphoneRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let headphones = self.snapshot.headphones, headphones.connected else {
                    self.stopHeadphoneRefresh()
                    return
                }
                Task { await self.readHeadphoneBattery(name: headphones.name, announce: false) }
            }
        }
        timer.tolerance = 30
        headphoneRefresh = timer
    }

    private func stopHeadphoneRefresh() {
        headphoneRefresh?.invalidate()
        headphoneRefresh = nil
    }

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onUpdate?(next)
    }
}

// MARK: - Core Audio

/// Small typed reads of Core Audio properties, nil when the object doesn't have one.
private enum AudioProps {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func ids(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func pid(_ process: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() as String?, !string.isEmpty
        else { return nil }
        return string
    }

    static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}

/// Listens to the Core Audio properties that change when recording starts or stops: the lists
/// of devices and audio processes, whether each input device runs, and whether each process
/// records. Events arrive only when something changes, so a quiet Mac costs nothing.
@MainActor
private final class AudioWatch {
    var onChange: (() -> Void)?
    private var registrations: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private var watched: (inputs: [AudioObjectID], processes: [AudioObjectID])?
    /// One block for every registration: removing a listener takes the very block that was added.
    private lazy var listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.onChange?() }
    }

    /// Listens to exactly these devices and processes. Returns whether anything changed.
    @discardableResult
    func watch(inputs: [AudioObjectID], processes: [AudioObjectID]) -> Bool {
        if let watched, watched.inputs == inputs, watched.processes == processes { return false }
        removeAll()
        watched = (inputs, processes)
        let system = AudioObjectID(kAudioObjectSystemObject)
        add(system, kAudioHardwarePropertyDevices)
        add(system, kAudioHardwarePropertyProcessObjectList)
        inputs.forEach { add($0, kAudioDevicePropertyDeviceIsRunningSomewhere) }
        processes.forEach { add($0, kAudioProcessPropertyIsRunningInput) }
        return true
    }

    func removeAll() {
        for var registration in registrations {
            // Objects that went away take their listeners with them; the error doesn't matter.
            _ = AudioObjectRemovePropertyListenerBlock(registration.object, &registration.address, .main, listener)
        }
        registrations.removeAll()
        watched = nil
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var address = AudioProps.address(selector)
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr else { return }
        registrations.append((object, address))
    }
}

// MARK: - Camera

/// The same for cameras, through CoreMediaIO: the device list and whether each one runs.
@MainActor
private final class CameraWatch {
    var onChange: (() -> Void)?
    private var registrations: [(object: CMIOObjectID, address: CMIOObjectPropertyAddress)] = []
    private var watched: [CMIOObjectID]?
    private lazy var listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.onChange?() }
    }

    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func devices() -> [CMIOObjectID] {
        var address = address(kCMIOHardwarePropertyDevices)
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return [] }
        return Array(devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    static func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = address(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var used: UInt32 = 0
        return CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr && value != 0
    }

    func watch(_ devices: [CMIOObjectID]) {
        if watched == devices { return }
        removeAll()
        watched = devices
        add(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        devices.forEach { add($0, kCMIODevicePropertyDeviceIsRunningSomewhere) }
    }

    func removeAll() {
        for var registration in registrations {
            _ = CMIOObjectRemovePropertyListenerBlock(registration.object, &registration.address, .main, listener)
        }
        registrations.removeAll()
        watched = nil
    }

    private func add(_ object: CMIOObjectID, _ selector: Int) {
        var address = Self.address(selector)
        guard CMIOObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr else { return }
        registrations.append((object, address))
    }
}

// MARK: - Processes

/// Which process a helper belongs to.
private enum ProcessOwner {
    private typealias Responsible = @convention(c) (pid_t) -> pid_t

    /// macOS's own answer to "which app is this process for", the one privacy prompts use.
    /// It isn't in a public header, so it's looked up at run time and skipped if it's gone.
    private static let responsibleFunction: Responsible? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Responsible.self)
    }()

    static func responsible(for pid: pid_t) -> pid_t? {
        guard let responsibleFunction else { return nil }
        let owner = responsibleFunction(pid)
        return owner > 0 ? owner : nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}

// MARK: - Bluetooth access

/// Asks for Bluetooth access without blocking. CoreBluetooth shows the permission prompt and
/// reports the answer later; IOBluetooth would wait for it on the calling thread.
@MainActor
private final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var onGranted: (() -> Void)?
    private var toldOff = false

    func whenGranted(_ action: @escaping () -> Void) {
        onGranted = action
        check()
    }

    /// Looks again after a denial: the user may have turned access on in System Settings since.
    /// Only reads the current answer, so it's cheap enough for every app switch.
    func recheck() {
        guard onGranted != nil, manager == nil else { return }
        check()
    }

    private func check() {
        switch CBManager.authorization {
        case .allowedAlways:
            grant()
        case .notDetermined:
            guard manager == nil else { return }
            manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        default:
            if !toldOff { log.notice("Bluetooth access is off; headphones won't show") }
            toldOff = true
        }
    }

    private func grant() {
        guard let action = onGranted else { return }
        onGranted = nil
        manager = nil
        if toldOff { log.notice("Bluetooth access is on; watching headphones") }
        action()
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch CBManager.authorization {
            case .allowedAlways: grant()
            case .notDetermined: break
            default:
                // Denied at the prompt: drop the manager so a later recheck can look again.
                manager = nil
                check()
            }
        }
    }
}
