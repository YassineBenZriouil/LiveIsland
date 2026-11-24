import AppKit
import Combine
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "lyrics")

/// Sing With Me: the lyrics of the song playing, from LRCLIB, following the song.
///
/// The only feature that talks to a third party, so it's off until the person turns it on.
/// It asks only while someone is looking (the Media tab's card, or the lyrics window) and a
/// song plays, once per song (answers are kept on disk), and never on a timer. The line on
/// screen moves with one timer set to the next line's start, planned again whenever the
/// player reports a seek, a pause or a new rate; with nothing on screen, nothing runs.
@MainActor
final class SingWithMe: ObservableObject {
    enum State: Equatable {
        /// Nothing asked yet: off, nothing playing, or waiting for the song to play.
        case idle
        case loading
        case found(Lyrics)
        case missing
        case failed
    }

    // Settings
    @Published var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Key.enabled)
            if isEnabled { load() } else { reset() }
        }
    }
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: Key.fontScale) } }
    @Published var alignment: LyricsAlignment { didSet { defaults.set(alignment.rawValue, forKey: Key.alignment) } }
    /// Seconds added to the player's position: positive shows the words sooner.
    @Published var offset: Double {
        didSet {
            defaults.set(offset, forKey: Key.offset)
            replan()
        }
    }
    /// Settings shows sizes in points or as a share of the screen.
    @Published var sizeInPercent: Bool { didSet { defaults.set(sizeInPercent, forKey: Key.percent) } }
    /// Where the window goes, per display (by its UUID), as `LyricsPlacement.saved`.
    @Published private(set) var placements: [String: String] { didSet { defaults.set(placements, forKey: Key.placements) } }

    // What's showing
    @Published private(set) var isOpen = false
    @Published private(set) var track: NowPlaying?
    @Published private(set) var state: State = .idle
    /// The line being sung, while lyrics are on screen.
    @Published private(set) var currentIndex: Int?

    /// Set by the island: the Media tab, with its card, is on screen.
    var cardVisible = false {
        didSet {
            guard cardVisible != oldValue else { return }
            demandChanged()
        }
    }

    /// Seeks the player showing; set by the model.
    var seek: ((Double) -> Void)?
    /// Asks Spotify and Music where they are (they don't say when someone seeks inside them).
    var refreshPlayers: (() -> Void)?

    private let provider = LyricsProvider()
    private let defaults = UserDefaults.standard
    private var queryKey: String?
    private var task: Task<Void, Never>?
    /// Counts lookups, so one that was replaced never clears or answers for the next.
    private var generation = 0
    /// A song LRCLIB couldn't be reached for, and when: asked again only after a while.
    private var failure: (key: String, at: Date)?
    private var lineTimer: Timer?
    private var playerRefresh: Timer?
    private var closeWork: DispatchWorkItem?
    /// Why the window is counting down to close: the player went away (true), or it's paused.
    private var closingForGone = false
    private static let retryAfter: TimeInterval = 120
    private static let closeAfterPause: TimeInterval = 30
    private static let closeAfterGone: TimeInterval = 3

    init() {
        defaults.register(defaults: [Key.enabled: false, Key.fontScale: 1.0, Key.offset: 0.0, Key.percent: false])
        isEnabled = defaults.bool(forKey: Key.enabled)
        fontScale = defaults.double(forKey: Key.fontScale)
        alignment = LyricsAlignment(rawValue: defaults.string(forKey: Key.alignment) ?? "") ?? .left
        offset = defaults.double(forKey: Key.offset)
        sizeInPercent = defaults.bool(forKey: Key.percent)
        placements = defaults.dictionary(forKey: Key.placements) as? [String: String] ?? [:]
    }

    /// Lyrics are wanted on screen right now.
    private var isWanted: Bool { isOpen || cardVisible }

    var lyrics: Lyrics? {
        if case .found(let lyrics) = state { return lyrics }
        return nil
    }

    /// Clicking a line seeks there: only for synced lyrics, on a track with a length.
    var canSeek: Bool { lyrics?.kind == .synced && (track?.duration ?? 0) > 0 && seek != nil }

    /// The words on the Media tab's card.
    var teaser: String? {
        guard let lyrics else { return nil }
        if lyrics.kind == .synced, let index = currentIndex, !lyrics.lines[index].isGap { return lyrics.lines[index].text }
        let position = track?.position(at: Date()) ?? 0
        return lyrics.teaser(at: position + offset)
    }

    // MARK: - Opening and closing

    func open() {
        guard !isOpen else { return }
        isOpen = true
        demandChanged()
        playerRefresh = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayers?() }
        }
        playerRefresh?.tolerance = 1
        refreshPlayers?()
        watchForStop()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        playerRefresh?.invalidate()
        playerRefresh = nil
        closeWork?.cancel()
        closeWork = nil
        demandChanged()
    }

    func toggle() { isOpen ? close() : open() }

    /// Seeks to the start of a line (where the words, with the offset, begin).
    func seek(toLine index: Int) {
        guard canSeek, let line = lyrics?.lines[safe: index] else { return }
        let target = max(0, line.time - offset + 0.02)
        seek?(min(target, track?.duration ?? target))
        // Feels instant even before the player reports the new position.
        if var moved = track {
            moved.elapsed = target
            moved.timestamp = Date()
            track = moved
            replan()
        }
    }

    // MARK: - The song

    /// Every change the player reports: a new song, a seek, a pause, a new rate.
    func update(track next: NowPlaying?) {
        // Artwork arrives as its own update; it changes nothing here, so skip it cheaply.
        guard next != track else { return }
        track = next
        let key = next.flatMap(LyricsQuery.init)?.key
        if key != queryKey {
            queryKey = key
            task?.cancel()
            task = nil
            generation += 1
            // A video or a stream without an artist can't be looked up.
            state = next != nil && key == nil ? .missing : .idle
            currentIndex = nil
        }
        load()
        replan()
        watchForStop()
    }

    /// Asks for the song's lyrics if they're wanted: from disk first, then LRCLIB, only
    /// while it plays.
    private func load() {
        guard isEnabled, isWanted, task == nil, state == .idle || state == .failed,
              let track, let query = LyricsQuery(track), query.key == queryKey else { return }
        if let failure, failure.key == query.key, Date().timeIntervalSince(failure.at) < Self.retryAfter { return }
        let playing = track.isPlaying
        let provider = provider
        generation += 1
        let lookup = generation
        task = Task { [weak self] in
            let cached = await Task.detached(priority: .utility) { provider.cached(query) }.value
            guard let self, self.generation == lookup, !Task.isCancelled else { return }
            if let cached {
                self.finish(cached)
                return
            }
            // Nothing on disk: LRCLIB is asked only while the song plays.
            guard playing else {
                self.task = nil
                return
            }
            self.state = .loading
            let answer = await Task.detached(priority: .utility) { await provider.fetch(query) }.value
            guard self.generation == lookup, !Task.isCancelled else { return }
            self.finish(answer)
        }
    }

    private func finish(_ answer: LyricsProvider.Answer) {
        task = nil
        switch answer {
        case .found(let lyrics): state = .found(lyrics)
        case .missing: state = .missing
        case .failed:
            state = .failed
            if let queryKey { failure = (queryKey, Date()) }
        }
        replan()
    }

    /// Tries LRCLIB again now, after it couldn't be reached.
    func retry() {
        failure = nil
        if state == .failed { state = .idle }
        load()
    }

    private func reset() {
        task?.cancel()
        task = nil
        generation += 1
        state = track != nil && queryKey == nil ? .missing : .idle
        currentIndex = nil
        stopTimer()
    }

    private func demandChanged() {
        if isWanted { load() }
        replan()
    }

    // MARK: - Timing

    /// Moves to the line being sung and sets one timer for the next. Nothing runs while
    /// nobody's looking, the song is paused, or the lyrics aren't synced.
    private func replan() {
        stopTimer()
        guard isWanted, let lyrics, lyrics.kind == .synced, let track, let position = track.position(at: Date()) else {
            if currentIndex != nil, lyrics?.kind != .synced { currentIndex = nil }
            return
        }
        let plan = LyricsTiming.plan(lyrics, position: position, rate: track.playbackRate, isPlaying: track.isPlaying, offset: offset)
        if plan.index != currentIndex { currentIndex = plan.index }
        guard let delay = plan.delay else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.replan() }
        }
        timer.tolerance = min(0.03, delay * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        lineTimer = timer
    }

    private func stopTimer() {
        lineTimer?.invalidate()
        lineTimer = nil
    }

    /// The window closes by itself when the song has been paused for a while, or its player
    /// went away.
    private func watchForStop() {
        guard isOpen else { return }
        let delay: TimeInterval?
        if track == nil { delay = Self.closeAfterGone } else if track?.isPlaying == false { delay = Self.closeAfterPause } else { delay = nil }
        guard let delay else {
            closeWork?.cancel()
            closeWork = nil
            return
        }
        // Already counting down for the same reason: keep that deadline.
        let gone = track == nil
        if closeWork != nil, closingForGone == gone { return }
        closeWork?.cancel()
        closingForGone = gone
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            if self.track == nil || self.track?.isPlaying == false {
                log.notice("Sing With Me closed: nothing playing")
                self.close()
            }
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Size and place

    func placement(for display: String) -> LyricsPlacement {
        LyricsPlacement(saved: placements[display])
    }

    func setPlacement(_ placement: LyricsPlacement, for display: String) {
        let saved = placement.saved
        if placements[display] != saved { placements[display] = saved }
    }

    func resetSize(for display: String) {
        placements[display] = nil
    }

    func changeFontScale(by step: Double) {
        let range = LyricsTypography.scaleRange
        fontScale = min(max(((fontScale + step) * 10).rounded() / 10, range.lowerBound), range.upperBound)
    }

    func nudgeOffset(by steps: Int) {
        offset = LyricsOffset.stepped(offset, by: steps)
    }

    private enum Key {
        static let enabled = "singWithMe"
        static let fontScale = "lyricsFontScale"
        static let alignment = "lyricsAlignment"
        static let offset = "lyricsOffset"
        static let percent = "lyricsSizeInPercent"
        static let placements = "lyricsPlacements"
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
