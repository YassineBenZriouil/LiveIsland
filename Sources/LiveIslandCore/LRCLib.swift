import Foundation

/// What Sing With Me asks LRCLIB about a song: the four things it needs, and nothing else.
public struct LyricsQuery: Equatable, Hashable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    /// Seconds; nil for a stream that doesn't say.
    public var duration: Double?

    public init(title: String, artist: String, album: String = "", duration: Double? = nil) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        self.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    /// The song playing, when there's enough to look it up: a title and an artist. A video or
    /// a podcast without an artist isn't worth asking about.
    public init?(_ track: NowPlaying) {
        self.init(title: track.title, artist: track.artist, album: track.album, duration: track.duration)
        guard !title.isEmpty, !artist.isEmpty else { return nil }
    }

    /// The same song however a player spells it: case, accents, spacing and punctuation don't
    /// matter, and the length counts in whole seconds.
    public var key: String {
        let seconds = duration.map { String(Int($0.rounded())) } ?? "-"
        return [Self.normalized(title), Self.normalized(artist), Self.normalized(album), seconds].joined(separator: "|")
    }

    /// A file name for the key: a 64-bit FNV-1a hash, so titles never reach the file system.
    public var fileName: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash) + ".json"
    }

    /// The title without what players add to it (" - Remastered 2011", "(feat. …)",
    /// "[Live]"), for the search that runs when the exact lookup finds nothing.
    public var searchTitle: String {
        var text = title
        if let dash = text.range(of: " - ", options: .backwards) {
            let tail = text[dash.upperBound...].lowercased()
            if Self.decorations.contains(where: tail.contains) { text = String(text[..<dash.lowerBound]) }
        }
        for (open, close) in [("(", ")"), ("[", "]")] {
            while let start = text.range(of: open, options: .backwards),
                  let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
                let inside = text[start.upperBound..<end.lowerBound].lowercased()
                guard Self.decorations.contains(where: inside.contains) else { break }
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    private static let decorations = ["remaster", "feat.", "feat ", "ft.", "with ", "live", "version", "edit", "mono",
                                      "stereo", "mix", "deluxe", "bonus", "explicit", "acoustic"]

    static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var result = ""
        var space = false
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if space, !result.isEmpty { result.append(" ") }
                result.unicodeScalars.append(scalar)
                space = false
            } else {
                space = true
            }
        }
        return result
    }
}

/// LRCLIB (lrclib.net), a free, open lyrics database: an exact lookup, then a search.
public enum LRCLib {
    public static let base = URL(string: "https://lrclib.net/api/")!
    /// A plain name for the app, never the person's.
    public static let userAgent = "LiveIsland (https://github.com/charonova/LiveIsland)"
    /// How far a match's length may be from the song's.
    public static let durationTolerance: Double = 3

    /// One song as LRCLIB answers it (a /get answer, or one of /search's).
    public struct Record: Codable, Equatable, Sendable {
        public var id: Int?
        public var trackName: String?
        public var artistName: String?
        public var albumName: String?
        public var duration: Double?
        public var instrumental: Bool?
        public var plainLyrics: String?
        public var syncedLyrics: String?

        public init(id: Int? = nil, trackName: String? = nil, artistName: String? = nil, albumName: String? = nil,
                    duration: Double? = nil, instrumental: Bool? = nil, plainLyrics: String? = nil, syncedLyrics: String? = nil) {
            self.id = id
            self.trackName = trackName
            self.artistName = artistName
            self.albumName = albumName
            self.duration = duration
            self.instrumental = instrumental
            self.plainLyrics = plainLyrics
            self.syncedLyrics = syncedLyrics
        }

        var hasSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var hasPlain: Bool { !(plainLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        /// The best of what it has: synced, else plain, else "instrumental". Nil when it has
        /// nothing usable.
        public var lyrics: Lyrics? {
            if let synced = syncedLyrics, let lyrics = Lyrics(lrc: synced) { return lyrics }
            if let plain = plainLyrics, let lyrics = Lyrics(plain: plain) { return lyrics }
            return instrumental == true ? .instrumental : nil
        }
    }

    /// The exact lookup. It needs all four values, so without an album or a length it's
    /// skipped and the search runs instead.
    public static func getURL(for query: LyricsQuery) -> URL? {
        guard let duration = query.duration, !query.album.isEmpty else { return nil }
        return url("get", [("track_name", query.title), ("artist_name", query.artist),
                           ("album_name", query.album), ("duration", String(Int(duration.rounded())))])
    }

    public static func searchURL(for query: LyricsQuery) -> URL? {
        url("search", [("track_name", query.searchTitle), ("artist_name", query.artist)])
    }

    private static func url(_ path: String, _ items: [(String, String)]) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        // `+` is a space to many servers: spell it out.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.percentEncodedQuery = query
        return components.url
    }

    public static func decodeRecord(_ data: Data) -> Record? {
        try? JSONDecoder().decode(Record.self, from: data)
    }

    public static func decodeSearch(_ data: Data) -> [Record] {
        (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// The search result to use: one within `durationTolerance` of the song's length (any
    /// length when it isn't known) that has words, preferring synced lyrics, then the closest
    /// length, then LRCLIB's order. An instrumental match only when nothing has words.
    public static func bestMatch(in records: [Record], duration: Double?) -> Record? {
        let close = records.enumerated().filter { _, record in
            guard let duration else { return true }
            guard let length = record.duration else { return false }
            return abs(length - duration) <= durationTolerance
        }
        func distance(_ record: Record) -> Double {
            guard let duration, let length = record.duration else { return 0 }
            return abs(length - duration)
        }
        let worded = close.filter { $0.element.lyrics.map { $0.kind != .instrumental } ?? false }
        let best = worded.min { a, b in
            if a.element.hasSynced != b.element.hasSynced { return a.element.hasSynced }
            if distance(a.element) != distance(b.element) { return distance(a.element) < distance(b.element) }
            return a.offset < b.offset
        }
        return best?.element ?? close.first(where: { $0.element.instrumental == true })?.element
    }
}

/// What's kept on disk for one song, so each song is asked about once.
public struct LyricsCacheEntry: Codable, Equatable, Sendable {
    /// Nil: LRCLIB has nothing for this song.
    public var lyrics: Lyrics?
    public var fetched: Date

    /// Found lyrics don't change; a miss is asked about again after a few days, in case
    /// someone has added them since.
    public static let foundLifetime: TimeInterval = 180 * 86_400
    public static let missLifetime: TimeInterval = 3 * 86_400

    public init(lyrics: Lyrics?, fetched: Date) {
        self.lyrics = lyrics
        self.fetched = fetched
    }

    public func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetched)
        // A clock set back makes the age negative: still fresh, not forever stale.
        return age < (lyrics == nil ? Self.missLifetime : Self.foundLifetime)
    }

    public func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(self)
    }

    public static func decode(_ data: Data) -> LyricsCacheEntry? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(LyricsCacheEntry.self, from: data)
    }
}
