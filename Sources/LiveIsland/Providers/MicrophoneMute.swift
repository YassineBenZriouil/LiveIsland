import AudioToolbox
import CoreAudio
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "microphone")

/// Mutes the Mac's microphone (the default input) from the island during a call. It only
/// listens while a call is on, and when the call ends it gives back a mute it made, so the
/// next call doesn't start silent without the person knowing. A mute made elsewhere (the
/// keyboard, Control Center, Sound settings) is shown but never undone.
@MainActor
final class MicrophoneMute: ObservableObject {
    struct State: Equatable {
        var device: String
        var muted: Bool
    }

    /// The input during a call; nil outside one, or when the input can't be muted.
    @Published private(set) var state: State?

    /// On while a call is on.
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            if isActive { begin() } else { end() }
        }
    }

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var control: MicrophoneMuting.Control?
    private var muting = MicrophoneMuting()
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private static var defaultInput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var volume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain)

    func toggle() {
        guard isActive, let control, device != kAudioObjectUnknown else { return }
        if state?.muted == true {
            apply(control, muted: false, volume: muting.unmute(control: control))
        } else {
            apply(control, muted: true, volume: muting.mute(control: control, currentVolume: Self.volume(of: device)))
        }
        read()
    }

    /// At quit: a mute LiveIsland made doesn't outlive it.
    func stop() {
        isActive = false
    }

    private func begin() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.inputChanged() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInput, .main, listener)
        defaultDeviceListener = listener
        attach()
    }

    private func end() {
        giveBackMute()
        detach()
        if let listener = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInput, .main, listener)
        }
        defaultDeviceListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
        control = nil
        publish(nil)
    }

    /// The call moved to another mic (headphones connected, say): the old one gets its sound
    /// back, and the new one is muted too, so the call stays muted as the person asked.
    private func inputChanged() {
        let wasMuted = muting.mutedByUs
        giveBackMute()
        attach()
        if wasMuted, let control, device != kAudioObjectUnknown {
            apply(control, muted: true, volume: muting.mute(control: control, currentVolume: Self.volume(of: device)))
            read()
        }
    }

    private func giveBackMute() {
        guard muting.mutedByUs, let control, device != kAudioObjectUnknown else { return }
        apply(control, muted: false, volume: muting.unmute(control: control))
    }

    private func apply(_ control: MicrophoneMuting.Control, muted: Bool, volume: Float?) {
        var status: OSStatus
        switch control {
        case .mute:
            var value: UInt32 = muted ? 1 : 0
            status = AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        case .volume:
            var value = Float32(volume ?? (muted ? 0 : MicrophoneMuting.fallbackVolume))
            status = AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        }
        if status != noErr { log.error("Couldn't \(muted ? "mute" : "unmute", privacy: .public) the microphone: \(status)") }
    }

    private func attach() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultInput, 0, nil, &size, &id)
        device = id
        guard id != kAudioObjectUnknown else {
            control = nil
            return publish(nil)
        }
        control = MicrophoneMuting.control(muteSettable: Self.isSettable(id, &Self.mute),
                                           volumeSettable: Self.isSettable(id, &Self.volume))
        for address in [Self.mute, Self.volume] {
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
        guard let control, device != kAudioObjectUnknown else { return publish(nil) }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &Self.mute) { AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &muted) }
        let isMuted = MicrophoneMuting.isMuted(control: control, muted: muted != 0, volume: Self.volume(of: device))
        if !isMuted, muting.mutedByUs { muting.unmutedElsewhere() }
        publish(State(device: OutputVolume.name(of: device) ?? "Microphone", muted: isMuted))
    }

    private func publish(_ next: State?) {
        if next != state { state = next }
    }

    private static func volume(of device: AudioObjectID) -> Float {
        var value: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(device, &volume) else { return 1 }
        AudioObjectGetPropertyData(device, &volume, 0, nil, &size, &value)
        return value
    }

    private static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
}
