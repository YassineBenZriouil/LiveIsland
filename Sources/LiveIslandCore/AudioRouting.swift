import Foundation

/// An output the island offers in its device menu: speakers, AirPods, a display, AirPlay.
public struct AudioOutputChoice: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case builtIn, bluetooth, wired, display, airPlay, virtual, other
    }

    /// Core Audio's device UID: it stays the same across reconnects, unlike the device ID.
    public var id: String
    public var name: String
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// Which outputs to offer, and in what order.
public enum AudioOutputs {
    /// The kind of a device from Core Audio's transport type (`kAudioDevicePropertyTransportType`,
    /// a four-character code), kept here so the mapping is tested without Core Audio.
    public static func kind(transport: UInt32) -> AudioOutputChoice.Kind {
        switch transport {
        case fourCC("bltn"): return .builtIn
        case fourCC("blue"), fourCC("blea"): return .bluetooth
        case fourCC("usb "), fourCC("fwre"), fourCC("pci "), fourCC("thun"): return .wired
        case fourCC("hdmi"), fourCC("dprt"), fourCC("dpst"): return .display
        case fourCC("airp"): return .airPlay
        case fourCC("virt"), fourCC("grup"): return .virtual
        default: return .other
        }
    }

    /// The outputs worth picking: without the private devices apps make for themselves
    /// (LiveIsland's own listening device for the waveform, Core Audio's default-device
    /// aggregates), each UID once, the Mac's speakers first, then headphones, then the rest by name.
    public static func choices(_ devices: [AudioOutputChoice]) -> [AudioOutputChoice] {
        var seen = Set<String>()
        let kept = devices.filter { device in
            guard !device.id.isEmpty, !isPrivate(uid: device.id) else { return false }
            return seen.insert(device.id).inserted
        }
        return kept.enumerated().sorted { lhs, rhs in
            let (l, r) = (rank(lhs.element.kind), rank(rhs.element.kind))
            if l != r { return l < r }
            let order = lhs.element.name.localizedStandardCompare(rhs.element.name)
            return order == .orderedSame ? lhs.offset < rhs.offset : order == .orderedAscending
        }.map(\.element)
    }

    /// Devices nobody would pick: they only exist for the app that made them.
    public static func isPrivate(uid: String) -> Bool {
        uid.hasPrefix("com.aissam.liveisland.") || uid.hasPrefix("CADefaultDeviceAggregate")
    }

    private static func rank(_ kind: AudioOutputChoice.Kind) -> Int {
        switch kind {
        case .builtIn: return 0
        case .bluetooth: return 1
        case .wired, .display, .airPlay, .other: return 2
        case .virtual: return 3
        }
    }

    static func fourCC(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// Muting the microphone for a call. Most inputs have a mute switch; some (many USB mics,
/// some built-in ones) only have a volume, so that goes to zero and comes back where it was.
/// LiveIsland only undoes a mute it made itself, and does so when the call ends, so the mic
/// is never left muted for the next call without the person knowing.
public struct MicrophoneMuting: Equatable, Sendable {
    public enum Control: Equatable, Sendable {
        case mute, volume
    }

    /// How a device can be muted, if at all.
    public static func control(muteSettable: Bool, volumeSettable: Bool) -> Control? {
        if muteSettable { return .mute }
        if volumeSettable { return .volume }
        return nil
    }

    /// Whether the input is silent, whichever control it has.
    public static func isMuted(control: Control, muted: Bool, volume: Float) -> Bool {
        switch control {
        case .mute: return muted
        case .volume: return volume <= 0
        }
    }

    /// The volume to bring back when unmuting a device that was muted with its volume at zero
    /// before LiveIsland touched it (so there's nothing to go back to).
    public static let fallbackVolume: Float = 0.75

    /// Whether LiveIsland muted the microphone (rather than the person, elsewhere).
    public private(set) var mutedByUs = false
    private var restoreVolume: Float?

    public init() {}

    /// Notes a mute LiveIsland makes; returns the volume to set when the control is the volume.
    public mutating func mute(control: Control, currentVolume: Float) -> Float? {
        mutedByUs = true
        guard control == .volume else { return nil }
        if currentVolume > 0 { restoreVolume = currentVolume }
        return 0
    }

    /// Notes an unmute; returns the volume to set when the control is the volume.
    public mutating func unmute(control: Control) -> Float? {
        defer {
            mutedByUs = false
            restoreVolume = nil
        }
        guard control == .volume else { return nil }
        return restoreVolume ?? Self.fallbackVolume
    }

    /// The mic was unmuted somewhere else (the keyboard, Control Center, Sound settings): it is
    /// no longer LiveIsland's mute to undo.
    public mutating func unmutedElsewhere() {
        mutedByUs = false
        restoreVolume = nil
    }
}

/// Whether a sound may play now. With "quiet in Focus" on, Do Not Disturb and every other Focus
/// silence LiveIsland's sounds; when macOS won't say (no permission yet), they play as before.
public enum SoundPolicy {
    public static func mayPlay(quietInFocus: Bool, focused: Bool?) -> Bool {
        !(quietInFocus && focused == true)
    }
}
