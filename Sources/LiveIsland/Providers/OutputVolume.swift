import AudioToolbox
import CoreAudio
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "volume")

/// The system output: which device it is, its volume and mute, kept current with Core Audio
/// listeners and settable from the island, with the other outputs to switch to.
@MainActor
final class OutputVolume {
    struct State: Equatable {
        var device: String
        var isBluetooth: Bool
        var isBuiltIn: Bool
        var volume: Float
        var muted: Bool
        /// Some outputs (HDMI, many interfaces) have no software volume.
        var canSetVolume: Bool
        /// The device's UID, to tick it in the device menu.
        var uid: String = ""
        /// Every output that can be picked, this one included.
        var choices: [AudioOutputChoice] = []
    }

    var onChange: ((State?) -> Void)?
    private(set) var state: State?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var deviceListListener: AudioObjectPropertyListenerBlock?
    /// The outputs connected now, read again only when Core Audio says the list changed.
    private var choices: [AudioOutputChoice] = []

    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var devices = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var volume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
        defaultDeviceListener = listener
        // Headphones connecting or leaving change the list; nothing runs in between.
        let listListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.choices = Self.outputs()
                self.read()
            }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devices, .main, listListener)
        deviceListListener = listListener
        choices = Self.outputs()
        attach()
    }

    func stop() {
        detach()
        if let listener = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
        }
        defaultDeviceListener = nil
        if let listener = deviceListListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devices, .main, listener)
        }
        deviceListListener = nil
    }

    /// Makes the output with this UID the Mac's sound output, as picking it in Control Center
    /// does. The default-device listener then follows it, so the island updates by itself.
    func select(_ uid: String) {
        guard uid != state?.uid, var id = Self.device(uid: uid) else { return }
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size), &id)
        if status != noErr { log.error("Couldn't switch the output: \(status)") }
    }

    func setVolume(_ value: Float) {
        guard device != kAudioObjectUnknown else { return }
        var volume = Float32(min(max(value, 0), 1))
        let status = AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if status != noErr { log.error("Couldn't set the volume: \(status)") }
        // Turning the volume up unmutes, like the keyboard keys do.
        if volume > 0, state?.muted == true { setMuted(false) }
        read()
    }

    func toggleMute() {
        setMuted(!(state?.muted ?? false))
    }

    private func setMuted(_ muted: Bool) {
        guard device != kAudioObjectUnknown else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        read()
    }

    /// Follows the default output, and listens to its volume and mute.
    private func attach() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id)
        device = id
        guard id != kAudioObjectUnknown else { return publish(nil) }
        for address in [Self.volume, Self.mute] {
            var address = address
            guard AudioObjectHasProperty(id, &address) else { continue }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.read() }
            }
            AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            deviceListeners.append((address, listener))
        }
        read()
    }

    private func detach() {
        for (address, listener) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        deviceListeners = []
    }

    private func read() {
        guard device != kAudioObjectUnknown else { return publish(nil) }
        var volume: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        let hasVolume = AudioObjectHasProperty(device, &Self.volume)
            && AudioObjectGetPropertyData(device, &Self.volume, 0, nil, &size, &volume) == noErr
        var settable: DarwinBoolean = false
        if hasVolume { AudioObjectIsPropertySettable(device, &Self.volume, &settable) }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &Self.mute) { AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &muted) }
        let transport = Self.transport(of: device)
        publish(State(device: Self.name(of: device) ?? "Output",
                      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                      isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                      volume: hasVolume ? volume : 1, muted: muted != 0, canSetVolume: settable.boolValue,
                      uid: Self.uid(of: device) ?? "", choices: choices))
    }

    private func publish(_ next: State?) {
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    /// Every device with output streams that isn't hidden, as menu choices.
    private static func outputs() -> [AudioOutputChoice] {
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &devices, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &devices, 0, nil, &size, &ids) == noErr else { return [] }
        let found = ids.compactMap { id -> AudioOutputChoice? in
            guard hasOutput(id), !isHidden(id), let uid = uid(of: id) else { return nil }
            return AudioOutputChoice(id: uid, name: name(of: id) ?? "Output", kind: AudioOutputs.kind(transport: transport(of: id)))
        }
        return AudioOutputs.choices(found)
    }

    private static func device(uid: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func isHidden(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(device, &address) else { return false }
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &hidden)
        return hidden != 0
    }

    static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func transport(of device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }
}
