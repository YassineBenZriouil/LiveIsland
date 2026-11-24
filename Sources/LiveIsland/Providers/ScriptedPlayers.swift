import AppKit
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "players")

/// Spotify and Music, read and controlled directly. The system's now-playing info only names
/// one app at a time; these two say when their track or state changes, and answer AppleScript,
/// so a paused Spotify stays one tap away while a video plays in the browser.
@MainActor
final class ScriptedPlayers {
    struct Player: Sendable {
        let bundleIdentifier: String
        let notification: String
        let query: String
        let commands: (playPause: String, next: String, previous: String)
    }

    nonisolated static let spotify = Player(
        bundleIdentifier: "com.spotify.client",
        notification: "com.spotify.client.PlaybackStateChanged",
        query: PlayerScript.guarded("""
        tell application id "com.spotify.client"
            set t to current track
            return {player state as string, name of t, artist of t, album of t, duration of t, player position, artwork url of t, id of t}
        end tell
        """, app: "com.spotify.client", otherwise: closedAnswer),
        commands: ("playpause", "next track", "previous track"))

    nonisolated static let music = Player(
        bundleIdentifier: "com.apple.Music",
        notification: "com.apple.Music.playerInfo",
        query: PlayerScript.guarded("""
        tell application id "com.apple.Music"
            set s to player state as string
            if s is "stopped" then return {s}
            set t to current track
            return {s, name of t, artist of t, album of t, duration of t, player position, "", persistent ID of t}
        end tell
        """, app: "com.apple.Music", otherwise: closedAnswer),
        commands: ("playpause", "next track", "previous track"))

    nonisolated static let all = [spotify, music]

    /// What a query answers when the app quit just before it ran: read like a stopped player.
    private nonisolated static let closedAnswer = #"return {"stopped"}"#

    /// A track coming up, as Music lists it.
    struct QueueItem: Equatable, Identifiable, Sendable {
        var title: String
        var artist: String
        var trackID: String
        var id: String { trackID }
    }

    var onChange: (([NowPlaying]) -> Void)?
    /// What plays next, per player. Only Music says; Spotify keeps its queue to itself.
    var onQueue: (([String: [QueueItem]]) -> Void)?
    private(set) var players: [String: NowPlaying] = [:]
    private var queues: [String: [QueueItem]] = [:]

    /// Compiled once: compiling is most of what an AppleScript query costs.
    private let scripts = ScriptCache()
    private var observers: [NSObjectProtocol] = []
    /// The last artwork per player, by track, so it's fetched once per track.
    private var artwork: [String: (track: String, data: Data?)] = [:]
    /// Spotify's covers come from its CDN. A slow network gives up quickly rather than
    /// holding the cover back for a minute; the track shows without one meanwhile.
    private let artworkSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let center = DistributedNotificationCenter.default()
        for player in Self.all {
            observers.append(center.addObserver(forName: Notification.Name(player.notification), object: nil, queue: .main) { [weak self] note in
                // "Stopped" comes as the app quits: asking it anything then could reopen it.
                let stopped = PlayerScript.state(ofNotice: note.userInfo) == .stopped
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if stopped { self.clear(player.bundleIdentifier) } else { self.refresh(player) }
                }
            })
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let bundle, self.handles(bundle) else { return }
                self.clear(bundle)
            }
        })
        refreshAll()
    }

    func stop() {
        running = false
        observers.forEach { DistributedNotificationCenter.default().removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        players = [:]
    }

    /// Positions drift when someone seeks inside the app, which sends no notice; the island
    /// calls this while it's open.
    func refreshAll() {
        for player in Self.all { refresh(player) }
    }

    func handles(_ bundleIdentifier: String?) -> Bool {
        Self.all.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    enum Command { case playPause, next, previous }

    func send(_ command: Command, to bundleIdentifier: String) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        let verb: String
        switch command {
        case .playPause: verb = player.commands.playPause
        case .next: verb = player.commands.next
        case .previous: verb = player.commands.previous
        }
        if command == .playPause, var info = players[bundleIdentifier] {
            info.elapsed = info.position(at: Date())
            info.timestamp = Date()
            info.isPlaying.toggle()
            players[bundleIdentifier] = info
            publish()
        }
        perform("tell application id \"\(player.bundleIdentifier)\" to \(verb)", then: player)
    }

    /// Plays a track the player named before: from history, or from Music's queue.
    func play(trackID: String, in bundleIdentifier: String) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }),
              trackID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == ":" })
        else { return }
        let source: String
        if bundleIdentifier == Self.spotify.bundleIdentifier {
            source = "tell application id \"com.spotify.client\" to play track \"\(trackID)\""
        } else {
            source = """
            tell application id "com.apple.Music"
                try
                    play (first track of current playlist whose persistent ID is "\(trackID)")
                on error
                    play (first track of library playlist 1 whose persistent ID is "\(trackID)")
                end try
            end tell
            """
        }
        perform(source, then: player)
    }

    /// Opens a player that isn't running and starts it playing: what tapping its icon means.
    /// The one script allowed to launch its app, so the one left unguarded.
    func launchAndPlay(_ bundleIdentifier: String) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        AppleScriptQueue.shared.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: "tell application id \"\(player.bundleIdentifier)\" to play")?.executeAndReturnError(&error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.refresh(player) }
        }
    }

    func seek(_ bundleIdentifier: String, to seconds: Double) {
        guard let player = Self.all.first(where: { $0.bundleIdentifier == bundleIdentifier }) else { return }
        perform("tell application id \"\(player.bundleIdentifier)\" to set player position to \(Int(seconds.rounded()))", then: player)
    }

    // MARK: - Reading

    /// Runs a command, guarded inside the script too: the app can quit between this check and
    /// the moment the script gets its turn on the queue.
    private func perform(_ source: String, then player: Player) {
        guard isRunning(player) else { return }
        let guarded = PlayerScript.guarded(source, app: player.bundleIdentifier)
        AppleScriptQueue.shared.async { [weak self] in
            var error: NSDictionary?
            NSAppleScript(source: guarded)?.executeAndReturnError(&error)
            if let error { log.error("\(player.bundleIdentifier, privacy: .public): \(error, privacy: .public)") }
            DispatchQueue.main.async { self?.refresh(player) }
        }
    }

    private func isRunning(_ player: Player) -> Bool {
        // Never script an app that isn't open: AppleScript would launch it. This only saves a
        // trip to the queue; the scripts check again as they run.
        !NSRunningApplication.runningApplications(withBundleIdentifier: player.bundleIdentifier).isEmpty
    }

    private func refresh(_ player: Player) {
        guard running else { return }
        guard isRunning(player) else { return clear(player.bundleIdentifier) }
        let known = artwork[player.bundleIdentifier]?.track
        let scripts = scripts
        AppleScriptQueue.shared.async { [weak self] in
            var error: NSDictionary?
            let result = scripts.script(player.query)?.executeAndReturnError(&error)
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != -1728 {
                // -1728 is "no current track", which is normal.
                log.error("Reading \(player.bundleIdentifier, privacy: .public) failed: \(code) \(error[NSAppleScript.errorMessage] as? String ?? "", privacy: .public)")
            }
            let read = result.flatMap { Self.parse($0, player: player) }
            var fetched: (track: String, data: Data?)?
            var upNext: [QueueItem]?
            // Music hands its cover over by AppleScript, so it's read here, once per track.
            // Spotify's is a download, which no script waits for (see `loadArtwork`).
            if let track = read?.trackID, track != known, player.bundleIdentifier == Self.music.bundleIdentifier {
                fetched = (track, Self.musicArtwork())
                // A new track: what follows it changed too.
                upNext = Self.musicUpNext()
            }
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.apply(read, from: player, fetched: fetched, upNext: upNext)
            }
        }
    }

    private func apply(_ read: Reading?, from player: Player, fetched: (track: String, data: Data?)?, upNext: [QueueItem]?) {
        let bundle = player.bundleIdentifier
        if let fetched { artwork[bundle] = fetched }
        var upNext = upNext
        if read == nil, queues[bundle] != nil { upNext = [] }
        if let upNext, queues[bundle] ?? [] != upNext {
            queues[bundle] = upNext.isEmpty ? nil : upNext
            onQueue?(queues)
        }
        var next = read?.info
        if let read, let track = read.trackID {
            if artwork[bundle]?.track == track {
                next?.artwork = artwork[bundle]?.data
            } else if let url = read.artworkURL.flatMap(URL.init(string:)), url.scheme == "https" {
                loadArtwork(from: url, track: track, for: bundle)
            } else {
                artwork[bundle] = (track, nil)
            }
        }
        guard players[bundle] != next else { return }
        players[bundle] = next
        publish()
    }

    /// Downloads a Spotify cover away from the scripts, so a pause tapped meanwhile goes
    /// through at once. The track shows first, its cover once it arrives.
    private func loadArtwork(from url: URL, track: String, for bundle: String) {
        // Marked before it arrives, so the refreshes in between don't ask again.
        artwork[bundle] = (track, nil)
        artworkSession.dataTask(with: url) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let image = ok && data?.isEmpty == false ? data : nil
            DispatchQueue.main.async {
                guard let self, self.running, self.artwork[bundle]?.track == track else { return }
                self.artwork[bundle] = (track, image)
                guard let image, var info = self.players[bundle] else { return }
                info.artwork = image
                self.players[bundle] = info
                self.publish()
            }
        }.resume()
    }

    /// Forgets a player that stopped or quit, and what it had queued.
    private func clear(_ bundle: String) {
        let had = players.removeValue(forKey: bundle) != nil
        if queues.removeValue(forKey: bundle) != nil { onQueue?(queues) }
        if had { publish() }
    }

    private func publish() {
        onChange?(players.values.sorted { $0.bundleIdentifier ?? "" < $1.bundleIdentifier ?? "" })
    }

    /// One query's answer: the track, the key its cover is kept under, and Spotify's cover link.
    private typealias Reading = (info: NowPlaying, trackID: String?, artworkURL: String?)

    private nonisolated static func parse(_ result: NSAppleEventDescriptor, player: Player) -> Reading? {
        func item(_ index: Int) -> NSAppleEventDescriptor? {
            index <= result.numberOfItems ? result.atIndex(index) : nil
        }
        guard let state = item(1)?.stringValue, state != "stopped",
              let title = item(2)?.stringValue, !title.isEmpty
        else { return nil }
        var duration = item(5)?.doubleValue ?? 0
        // Spotify counts in milliseconds, Music in seconds.
        if player.bundleIdentifier == spotify.bundleIdentifier { duration /= 1000 }
        let info = NowPlaying(
            title: title, artist: item(3)?.stringValue ?? "", album: item(4)?.stringValue ?? "",
            bundleIdentifier: player.bundleIdentifier, duration: duration > 0 ? duration : nil,
            elapsed: item(6)?.doubleValue, timestamp: Date(), playbackRate: 1, isPlaying: state == "playing",
            trackID: item(8)?.stringValue)
        let url = item(7)?.stringValue
        return (info, item(8)?.stringValue ?? title, url?.isEmpty == false ? url : nil)
    }

    /// The tracks after the current one in Music's playlist. With shuffle on, the order is
    /// Music's secret, so there's nothing to show. Runs on the AppleScript queue.
    private nonisolated static func musicUpNext() -> [QueueItem] {
        let source = PlayerScript.guarded("""
        tell application id "com.apple.Music"
            if shuffle enabled then return {}
            set p to current playlist
            set i to index of current track
            set n to count of tracks of p
            set out to {}
            repeat with k from (i + 1) to (i + 8)
                if k > n then exit repeat
                set t to track k of p
                set end of out to {name of t, artist of t, persistent ID of t}
            end repeat
            return out
        end tell
        """, app: music.bundleIdentifier, otherwise: "return {}")
        var error: NSDictionary?
        guard let list = NSAppleScript(source: source)?.executeAndReturnError(&error), list.numberOfItems > 0 else { return [] }
        return (1...list.numberOfItems).compactMap { index in
            guard let entry = list.atIndex(index), entry.numberOfItems >= 3,
                  let title = entry.atIndex(1)?.stringValue, let id = entry.atIndex(3)?.stringValue
            else { return nil }
            return QueueItem(title: title, artist: entry.atIndex(2)?.stringValue ?? "", trackID: id)
        }
    }

    /// Music hands over the cover itself, by AppleScript. Runs on the AppleScript queue.
    private nonisolated static func musicArtwork() -> Data? {
        let source = PlayerScript.guarded(
            "tell application id \"com.apple.Music\" to get raw data of artwork 1 of current track",
            app: music.bundleIdentifier)
        var error: NSDictionary?
        let data = NSAppleScript(source: source)?.executeAndReturnError(&error).data
        return data?.isEmpty == false ? data : nil
    }
}

/// Compiled AppleScripts by source. Used only on the AppleScript queue.
private final class ScriptCache: @unchecked Sendable {
    private var compiled: [String: NSAppleScript] = [:]

    func script(_ source: String) -> NSAppleScript? {
        if let script = compiled[source] { return script }
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        script.compileAndReturnError(&error)
        compiled[source] = script
        return script
    }
}
