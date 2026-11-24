import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Player scripts")
struct PlayerScriptTests {
    @Test func scriptAsksWhetherTheAppRunsBeforeTellingIt() {
        let script = PlayerScript.guarded(#"tell application id "com.spotify.client" to playpause"#,
                                          app: "com.spotify.client")
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.first == #"if application id "com.spotify.client" is running then"#)
        let tell = lines.firstIndex { $0.contains("tell application") }
        let end = lines.firstIndex(of: "end if")
        #expect(tell != nil && end != nil && tell! < end!, "the tell sits inside the check")
    }

    @Test func closedAppGetsTheFallbackAnswer() {
        let body = "tell application id \"com.apple.Music\"\nreturn {\"playing\"}\nend tell"
        let script = PlayerScript.guarded(body, app: "com.apple.Music", otherwise: #"return {"stopped"}"#)
        #expect(script.hasSuffix("end if\nreturn {\"stopped\"}"))
    }

    @Test func oddIdentifierNeverReachesTheScript() {
        let script = PlayerScript.guarded("tell application id \"x\" to play", app: #"x" to quit --"#, otherwise: "return {}")
        #expect(script == "return {}")
    }

    @Test func readsTheStateFromRealNotices() {
        // Shaped like Spotify's com.spotify.client.PlaybackStateChanged and Music's com.apple.Music.playerInfo.
        let spotifyPlaying: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Song", "Artist": "Band",
                                                  "Track ID": "spotify:track:abc123", "Playback Position": 12.5]
        let spotifyQuit: [AnyHashable: Any] = ["Player State": "Stopped", "Track ID": "spotify:track:abc123"]
        let musicPaused: [AnyHashable: Any] = ["Player State": "Paused", "Name": "Song", "PersistentID": 1234567890]
        let musicStopped: [AnyHashable: Any] = ["Player State": "Stopped"]
        #expect(PlayerScript.state(ofNotice: spotifyPlaying) == .playing)
        #expect(PlayerScript.state(ofNotice: spotifyQuit) == .stopped)
        #expect(PlayerScript.state(ofNotice: musicPaused) == .paused)
        #expect(PlayerScript.state(ofNotice: musicStopped) == .stopped)
    }

    @Test func noticeWithoutAStateIsUnknown() {
        #expect(PlayerScript.state(ofNotice: nil) == .unknown)
        #expect(PlayerScript.state(ofNotice: ["Name": "Song"]) == .unknown)
        #expect(PlayerScript.state(ofNotice: ["Player State": 3]) == .unknown)
    }
}
