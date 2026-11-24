import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Output devices")
struct AudioOutputsTests {
    @Test func transportCodesMapToKinds() {
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("bltn")) == .builtIn)
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("blue")) == .bluetooth)
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("blea")) == .bluetooth)
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("usb ")) == .wired)
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("hdmi")) == .display)
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("airp")) == .airPlay)
        #expect(AudioOutputs.kind(transport: AudioOutputs.fourCC("grup")) == .virtual)
        #expect(AudioOutputs.kind(transport: 0) == .other)
        // Core Audio's kAudioDeviceTransportTypeBluetooth is 'blue' = 0x626C7565.
        #expect(AudioOutputs.fourCC("blue") == 0x626C_7565)
    }

    @Test func hidesPrivateDevicesAndSortsSpeakersFirst() {
        let devices = [
            AudioOutputChoice(id: "com.aissam.liveisland.levels.1234", name: "LiveIsland levels", kind: .virtual),
            AudioOutputChoice(id: "CADefaultDeviceAggregate-1203-0", name: "CADefaultDeviceAggregate-1203-0", kind: .virtual),
            AudioOutputChoice(id: "BlackHole2ch_UID", name: "BlackHole 2ch", kind: .virtual),
            AudioOutputChoice(id: "LG-HDMI", name: "LG UltraFine", kind: .display),
            AudioOutputChoice(id: "AA-BB-CC:output", name: "AirPods Pro", kind: .bluetooth),
            AudioOutputChoice(id: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", kind: .builtIn),
            AudioOutputChoice(id: "AppleUSBAudioEngine:Focusrite", name: "Focusrite USB", kind: .wired),
        ]
        #expect(AudioOutputs.choices(devices).map(\.name)
            == ["MacBook Pro Speakers", "AirPods Pro", "Focusrite USB", "LG UltraFine", "BlackHole 2ch"])
    }

    @Test func listsEachDeviceOnce() {
        let speakers = AudioOutputChoice(id: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", kind: .builtIn)
        #expect(AudioOutputs.choices([speakers, speakers]).count == 1)
        #expect(AudioOutputs.choices([AudioOutputChoice(id: "", name: "Nameless", kind: .other)]).isEmpty)
    }
}

@Suite("Microphone mute")
struct MicrophoneMutingTests {
    @Test func prefersTheMuteSwitch() {
        #expect(MicrophoneMuting.control(muteSettable: true, volumeSettable: true) == .mute)
        #expect(MicrophoneMuting.control(muteSettable: false, volumeSettable: true) == .volume)
        #expect(MicrophoneMuting.control(muteSettable: false, volumeSettable: false) == nil)
    }

    @Test func aVolumeOnlyMicComesBackWhereItWas() {
        var muting = MicrophoneMuting()
        #expect(muting.mute(control: .volume, currentVolume: 0.6) == 0)
        #expect(muting.mutedByUs)
        #expect(MicrophoneMuting.isMuted(control: .volume, muted: false, volume: 0))
        #expect(muting.unmute(control: .volume) == 0.6)
        #expect(!muting.mutedByUs)
    }

    @Test func aMicAlreadyAtZeroComesBackAudible() {
        var muting = MicrophoneMuting()
        _ = muting.mute(control: .volume, currentVolume: 0)
        #expect(muting.unmute(control: .volume) == MicrophoneMuting.fallbackVolume)
    }

    @Test func theMuteSwitchNeedsNoVolume() {
        var muting = MicrophoneMuting()
        #expect(muting.mute(control: .mute, currentVolume: 0.8) == nil)
        #expect(MicrophoneMuting.isMuted(control: .mute, muted: true, volume: 0.8))
        #expect(muting.unmute(control: .mute) == nil)
    }

    @Test func anUnmuteElsewhereIsNoLongerOursToUndo() {
        var muting = MicrophoneMuting()
        _ = muting.mute(control: .volume, currentVolume: 0.5)
        muting.unmutedElsewhere()
        #expect(!muting.mutedByUs)
        // A later mute and unmute doesn't bring back the old volume.
        _ = muting.mute(control: .volume, currentVolume: 0.9)
        #expect(muting.unmute(control: .volume) == 0.9)
    }
}

@Suite("Sounds in Focus")
struct SoundPolicyTests {
    @Test func staysQuietOnlyInAKnownFocus() {
        #expect(!SoundPolicy.mayPlay(quietInFocus: true, focused: true))
        #expect(SoundPolicy.mayPlay(quietInFocus: true, focused: false))
        #expect(SoundPolicy.mayPlay(quietInFocus: true, focused: nil))
        #expect(SoundPolicy.mayPlay(quietInFocus: false, focused: true))
    }
}
