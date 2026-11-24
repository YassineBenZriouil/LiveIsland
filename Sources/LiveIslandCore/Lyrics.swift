import Foundation

/// One line of a song's lyrics. An empty `text` is a gap: an instrumental break between
/// verses, shown as a quiet note rather than as the last line sung.
public struct LyricLine: Equatable, Hashable, Sendable, Codable {
    /// When the line starts, in seconds from the start of the track (0 for unsynced lyrics).
    public var time: Double
    public var text: String

    public init(time: Double, text: String) {
        self.time = time
        self.text = text
    }

    public var isGap: Bool { text.isEmpty }
}

/// A song's lyrics as Sing With Me shows them.
public struct Lyrics: Equatable, Sendable, Codable {
    public enum Kind: String, Equatable, Sendable, Codable {
        /// Lines with times: the current one follows the song.
        case synced
        /// Words without times: shown as they are.
        case plain
        /// No words at all.
        case instrumental
    }

    public var kind: Kind
    /// Sorted by time; for plain lyrics every time is 0.
    public var lines: [LyricLine]

    public init(kind: Kind, lines: [LyricLine]) {
        self.kind = kind
        self.lines = kind == .synced ? lines.enumerated().sorted { a, b in
            // A stable sort: lines stamped with the same time keep their order in the file.
            a.element.time == b.element.time ? a.offset < b.offset : a.element.time < b.element.time
        }.map(\.element) : lines
    }

    public static let instrumental = Lyrics(kind: .instrumental, lines: [])

    /// Synced lyrics from LRC text, or nil when it holds no timed line.
    public init?(lrc text: String) {
        let lines = LRC.parse(text)
        guard lines.contains(where: { !$0.isGap }) else { return nil }
        self.init(kind: .synced, lines: lines)
    }

    /// Unsynced lyrics, one line per line of text. Runs of blank lines become one gap, and
    /// blank lines at either end go.
    public init?(plain text: String) {
        var lines: [LyricLine] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty, lines.last?.isGap ?? true { continue }
            lines.append(LyricLine(time: 0, text: line))
        }
        while lines.last?.isGap == true { lines.removeLast() }
        guard !lines.isEmpty else { return nil }
        self.init(kind: .plain, lines: lines)
    }

    /// The line being sung at `time`: the last one that has started. Nil before the first line,
    /// and always for unsynced lyrics. A binary search, so a long song costs nothing.
    public func index(at time: Double) -> Int? {
        guard kind == .synced, !lines.isEmpty, time.isFinite else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let middle = (low + high) / 2
            if lines[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    /// When the next line starts after `time`, for the one timer that moves to it. Nil when
    /// nothing comes later, or the lyrics aren't synced.
    public func nextChange(after time: Double) -> Double? {
        guard kind == .synced, time.isFinite else { return nil }
        let next = (index(at: time) ?? -1) + 1
        // Lines stamped with the same time start together: the next change is a later time.
        var position = next
        while position < lines.count, lines[position].time <= time { position += 1 }
        return position < lines.count ? lines[position].time : nil
    }

    /// The words to tease on the Media tab's card at `time`: the line being sung, else the next
    /// one coming (before the first line, or in a break).
    public func teaser(at time: Double) -> String? {
        switch kind {
        case .instrumental: return nil
        case .plain: return lines.first(where: { !$0.isGap })?.text
        case .synced:
            if let index = index(at: time), !lines[index].isGap { return lines[index].text }
            let start = (index(at: time) ?? -1) + 1
            return lines[min(start, lines.count)...].first(where: { !$0.isGap })?.text
        }
    }
}

/// The LRC format: `[mm:ss.xx]text`, with any number of time tags on a line (a chorus sung
/// twice), `[offset:+250]` in milliseconds, and metadata tags (`[ar:…]`, `[ti:…]`) ignored.
public enum LRC {
    public static func parse(_ text: String) -> [LyricLine] {
        var offset: Double = 0
        var lines: [LyricLine] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: true) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var times: [Double] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let time = timestamp(tag) {
                    times.append(time)
                } else if let value = tagValue(tag, named: "offset"), let milliseconds = Double(value.trimmingCharacters(in: .whitespaces)) {
                    offset = milliseconds / 1000
                } else if !times.isEmpty {
                    // A bracket after the times is part of the words ("[Chorus]").
                    break
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !times.isEmpty else { continue }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { lines.append(LyricLine(time: time, text: words)) }
        }
        // A positive offset makes the words come sooner, as in every LRC player.
        let shifted = lines.map { LyricLine(time: max(0, $0.time - offset), text: $0.text) }
        return Lyrics(kind: .synced, lines: shifted).lines
    }

    /// `mm:ss`, `mm:ss.x`, `mm:ss.xx`, `mm:ss.xxx`, or `mm:ss:xx` (some files use a colon).
    static func timestamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3,
              let minutes = Int(parts[0]), minutes >= 0,
              parts[0].allSatisfy(\.isASCII) else { return nil }
        var secondsText = String(parts[1])
        if parts.count == 3 { secondsText += "." + parts[2] }
        guard !secondsText.isEmpty, secondsText.allSatisfy({ $0.isNumber || $0 == "." }), secondsText.first != ".",
              let seconds = Double(secondsText), seconds < 60 else { return nil }
        return Double(minutes) * 60 + seconds
    }

    private static func tagValue(_ tag: Substring, named name: String) -> String? {
        guard let colon = tag.firstIndex(of: ":"),
              tag[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name else { return nil }
        return String(tag[tag.index(after: colon)...])
    }
}

/// When the line on screen next changes. Sing With Me sets one timer to that moment (and
/// plans again on a seek, a pause or a new rate) instead of checking the time over and over.
public struct LyricsTiming: Equatable, Sendable {
    /// The line being sung, or nil before the first.
    public var index: Int?
    /// Seconds of wall-clock time until the next line, or nil when nothing will change on its
    /// own (paused, at the end, or unsynced).
    public var delay: TimeInterval?

    public init(index: Int?, delay: TimeInterval?) {
        self.index = index
        self.delay = delay
    }

    /// `position` is where the track is now; `offset` moves the words (positive: sooner).
    public static func plan(_ lyrics: Lyrics, position: Double, rate: Double, isPlaying: Bool, offset: Double) -> LyricsTiming {
        let time = position + offset
        let index = lyrics.index(at: time)
        guard isPlaying, let next = lyrics.nextChange(after: time) else { return LyricsTiming(index: index, delay: nil) }
        let speed = rate > 0 ? rate : 1
        // A hair past the line's start, so the timer never lands just before it and plans again
        // for the same line.
        return LyricsTiming(index: index, delay: max(0.01, (next - time) / speed + 0.005))
    }
}
