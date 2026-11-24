import CoreGraphics
import Foundation
import Testing
@testable import LiveIslandCore

/// LRC text shaped like LRCLIB's: metadata tags, an offset, a chorus with two times, a
/// break, and a bracket that's part of the words.
private let songLRC = """
[ar:Example Artist]
[ti:Example Song]
[length: 03:12]
[00:00.05] First line of the song
[00:06.51] Second line comes in
[00:13.75][01:02.00] The chorus, sung twice
[00:24.41]
[00:30.06] [Bridge] after the break
[00:37.420] Three-digit milliseconds
[01:10] No fraction at all
"""

/// A compact /api/get answer, as LRCLIB sends it (lyrics trimmed).
private let getJSON = #"{"id":19080,"name":"Example Song","trackName":"Example Song","artistName":"Example Artist","albumName":"Example Album","duration":355.0,"instrumental":false,"hasWordSync":false,"plainLyrics":"First line\nSecond line\n\nThird line","syncedLyrics":"[00:00.05] First line\n[00:06.51] Second line\n[00:10.00] \n[00:13.75] Third line","lyricsfile":"version: '1.0'"}"#

/// A compact /api/search answer: a live take that's too long, a plain-only match, a synced
/// match two seconds off, and an instrumental.
private let searchJSON = #"[{"id":1,"trackName":"Example Song (Live)","artistName":"Example Artist","albumName":"Live","duration":402.0,"instrumental":false,"plainLyrics":"Live words","syncedLyrics":"[00:01.00] Live words"},{"id":2,"trackName":"Example Song","artistName":"Example Artist","albumName":"Example Album","duration":354.0,"instrumental":false,"plainLyrics":"Plain words","syncedLyrics":null},{"id":3,"trackName":"Example Song","artistName":"Example Artist","albumName":"Greatest Hits","duration":357.0,"instrumental":false,"plainLyrics":"Synced words","syncedLyrics":"[00:01.00] Synced words"},{"id":4,"trackName":"Example Song","artistName":"Example Artist","albumName":"Karaoke","duration":355.0,"instrumental":true,"plainLyrics":null,"syncedLyrics":null}]"#

@Suite("Sing With Me: lyrics")
struct LyricsTests {
    @Test func parsesTimesTagsAndBreaks() throws {
        let lines = LRC.parse(songLRC)
        #expect(lines.map(\.time) == [0.05, 6.51, 13.75, 24.41, 30.06, 37.42, 62, 70])
        #expect(lines[0].text == "First line of the song")
        #expect(lines[2].text == "The chorus, sung twice")
        #expect(lines[6].text == "The chorus, sung twice", "a line with two times shows at both")
        #expect(lines[3].isGap, "an empty line is a break")
        #expect(lines[4].text == "[Bridge] after the break", "a bracket after the time is words")
        #expect(lines.allSatisfy { !$0.text.contains("Example Artist") }, "metadata tags are not lines")
    }

    @Test func appliesTheOffsetTag() {
        let lines = LRC.parse("[offset:+250]\n[00:10.00] Sooner\n[00:00.10] Never before zero")
        #expect(lines.map(\.time) == [0, 9.75])
        #expect(LRC.parse("[offset:-500]\n[00:10.00] Later").map(\.time) == [10.5])
    }

    @Test func readsEveryTimestampShape() {
        #expect(LRC.timestamp("01:02") == 62)
        #expect(LRC.timestamp("01:02.5") == 62.5)
        #expect(LRC.timestamp("01:02.50") == 62.5)
        #expect(LRC.timestamp("01:02.500") == 62.5)
        #expect(LRC.timestamp("01:02:50") == 62.5)
        #expect(LRC.timestamp("120:00.00") == 7200)
        #expect(LRC.timestamp("ar:Queen") == nil)
        #expect(LRC.timestamp("00:75.00") == nil)
        #expect(LRC.timestamp("-1:00") == nil)
        #expect(LRC.timestamp("00:.5") == nil)
        #expect(LRC.timestamp("") == nil)
    }

    @Test func textWithoutTimesIsNotSynced() {
        #expect(Lyrics(lrc: "Just words\nNo times") == nil)
        #expect(Lyrics(lrc: "[00:01.00]\n[00:02.00]") == nil, "only breaks")
        #expect(Lyrics(lrc: "") == nil)
    }

    @Test func plainLyricsKeepOneBreakBetweenVerses() throws {
        let lyrics = try #require(Lyrics(plain: "\n\nVerse one\r\nline two\n\n\n\nVerse two\n\n"))
        #expect(lyrics.kind == .plain)
        #expect(lyrics.lines.map(\.text) == ["Verse one", "line two", "", "Verse two"])
        #expect(Lyrics(plain: " \n \n") == nil)
    }

    @Test func findsTheLineBeingSung() throws {
        let lyrics = try #require(Lyrics(lrc: songLRC))
        #expect(lyrics.index(at: 0) == nil, "before the first line")
        #expect(lyrics.index(at: 0.05) == 0)
        #expect(lyrics.index(at: 6.5) == 0)
        #expect(lyrics.index(at: 6.51) == 1)
        #expect(lyrics.index(at: 25) == 3)
        #expect(lyrics.index(at: 1_000) == 7, "the last line stays after it")
        #expect(lyrics.index(at: .nan) == nil)
        #expect(Lyrics(plain: "Words")?.index(at: 10) == nil, "unsynced lyrics have no current line")
    }

    @Test func knowsWhenTheNextLineStarts() throws {
        let lyrics = try #require(Lyrics(lrc: songLRC))
        #expect(lyrics.nextChange(after: 0) == 0.05)
        #expect(lyrics.nextChange(after: 0.05) == 6.51)
        #expect(lyrics.nextChange(after: 61.9) == 62)
        #expect(lyrics.nextChange(after: 70) == nil, "nothing after the last line")
        let same = try #require(Lyrics(lrc: "[00:01.00] A\n[00:01.00] B\n[00:02.00] C"))
        #expect(same.lines.map(\.text) == ["A", "B", "C"], "lines at the same time keep their order")
        #expect(same.nextChange(after: 1) == 2, "lines at the same time start together")
    }

    @Test func teasesTheLineOrTheNextOne() throws {
        let lyrics = try #require(Lyrics(lrc: songLRC))
        #expect(lyrics.teaser(at: 0) == "First line of the song", "before it starts: what comes first")
        #expect(lyrics.teaser(at: 7) == "Second line comes in")
        #expect(lyrics.teaser(at: 25) == "[Bridge] after the break", "in a break: what comes next")
        #expect(Lyrics(plain: "\nOpening words\nMore")?.teaser(at: 99) == "Opening words")
        #expect(Lyrics.instrumental.teaser(at: 0) == nil)
    }

    @Test func plansOneTimerToTheNextLine() throws {
        let lyrics = try #require(Lyrics(lrc: songLRC))
        let playing = LyricsTiming.plan(lyrics, position: 5, rate: 1, isPlaying: true, offset: 0)
        #expect(playing.index == 0)
        #expect(abs((playing.delay ?? 0) - 1.515) < 0.001)
        let fast = LyricsTiming.plan(lyrics, position: 5, rate: 2, isPlaying: true, offset: 0)
        #expect(abs((fast.delay ?? 0) - 0.76) < 0.001, "twice as fast, half the wait")
        let paused = LyricsTiming.plan(lyrics, position: 5, rate: 1, isPlaying: false, offset: 0)
        #expect(paused == LyricsTiming(index: 0, delay: nil), "paused: no timer")
        let sooner = LyricsTiming.plan(lyrics, position: 6, rate: 1, isPlaying: true, offset: 0.6)
        #expect(sooner.index == 1, "a positive offset shows the words sooner")
        let end = LyricsTiming.plan(lyrics, position: 80, rate: 1, isPlaying: true, offset: 0)
        #expect(end == LyricsTiming(index: 7, delay: nil))
        let zeroRate = LyricsTiming.plan(lyrics, position: 5, rate: 0, isPlaying: true, offset: 0)
        #expect(zeroRate.delay != nil, "a player that reports no rate while playing plays at 1×")
    }
}

@Suite("Sing With Me: LRCLIB")
struct LRCLibTests {
    let query = LyricsQuery(title: "Example Song", artist: "Example Artist", album: "Example Album", duration: 354.95)

    @Test func asksForOnlyTheFourThings() throws {
        let url = try #require(LRCLib.getURL(for: query))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(url.host == "lrclib.net")
        #expect(url.path == "/api/get")
        #expect(Set(items.map(\.name)) == ["track_name", "artist_name", "album_name", "duration"])
        #expect(items.first { $0.name == "duration" }?.value == "355")
        let search = try #require(LRCLib.searchURL(for: query))
        #expect(search.path == "/api/search")
        #expect(Set(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []) == ["track_name", "artist_name"])
    }

    @Test func spellsOutPlusSigns() throws {
        let url = try #require(LRCLib.searchURL(for: LyricsQuery(title: "1+1", artist: "A & B")))
        #expect(url.absoluteString.contains("1%2B1"))
        #expect(url.absoluteString.contains("A%20%26%20B"))
    }

    @Test func skipsTheExactLookupWithoutAnAlbumOrLength() {
        #expect(LRCLib.getURL(for: LyricsQuery(title: "Song", artist: "Artist", album: "", duration: 200)) == nil)
        #expect(LRCLib.getURL(for: LyricsQuery(title: "Song", artist: "Artist", album: "Album", duration: nil)) == nil)
        #expect(LRCLib.searchURL(for: LyricsQuery(title: "Song", artist: "Artist")) != nil)
    }

    @Test func needsATitleAndAnArtist() {
        #expect(LyricsQuery(NowPlaying(title: "A video", artist: "")) == nil)
        #expect(LyricsQuery(NowPlaying(title: "  ", artist: "Artist")) == nil)
        #expect(LyricsQuery(NowPlaying(title: "Song", artist: "Artist", duration: .infinity))?.duration == nil)
    }

    @Test func decodesAnExactAnswer() throws {
        let record = try #require(LRCLib.decodeRecord(Data(getJSON.utf8)))
        #expect(record.id == 19080)
        let lyrics = try #require(record.lyrics)
        #expect(lyrics.kind == .synced, "synced lyrics win over plain")
        #expect(lyrics.lines.map(\.text) == ["First line", "Second line", "", "Third line"])
    }

    @Test func fallsBackToPlainThenInstrumental() throws {
        let plain = LRCLib.Record(plainLyrics: "Only words", syncedLyrics: "")
        #expect(plain.lyrics?.kind == .plain)
        #expect(LRCLib.Record(instrumental: true).lyrics == .instrumental)
        #expect(LRCLib.Record(instrumental: false, plainLyrics: " ").lyrics == nil)
        #expect(LRCLib.decodeRecord(Data(#"{"code":404,"name":"TrackNotFound","message":"Failed to find specified track"}"#.utf8))?.lyrics == nil)
    }

    @Test func picksTheBestSearchMatch() throws {
        let records = LRCLib.decodeSearch(Data(searchJSON.utf8))
        #expect(records.count == 4)
        let best = try #require(LRCLib.bestMatch(in: records, duration: 355))
        #expect(best.id == 3, "synced within 3 s beats plain that's closer; the live take is too long")
        #expect(LRCLib.bestMatch(in: records, duration: 402)?.id == 1)
        #expect(LRCLib.bestMatch(in: records, duration: 100) == nil, "nothing near that length")
        #expect(LRCLib.bestMatch(in: records, duration: nil)?.id == 1, "without a length: the first synced one")
        #expect(LRCLib.bestMatch(in: [records[3]], duration: 355)?.instrumental == true, "instrumental when nothing has words")
        #expect(LRCLib.decodeSearch(Data("not json".utf8)).isEmpty)
    }

    @Test func sameSongSameKey() {
        let a = LyricsQuery(title: "Beyoncé  Song!", artist: "The Artist", album: "Album", duration: 200.4)
        let b = LyricsQuery(title: "beyonce song", artist: "THE ARTIST", album: "album", duration: 199.6)
        #expect(a.key == b.key)
        #expect(a.fileName == b.fileName)
        #expect(a.fileName.hasSuffix(".json"))
        #expect(a.fileName.count == 21)
        #expect(!a.fileName.lowercased().contains("beyonce"), "titles never reach the file system")
        let other = LyricsQuery(title: "beyonce song", artist: "the artist", album: "album", duration: 230)
        #expect(a.key != other.key, "another length is another recording")
    }

    @Test func searchesWithoutWhatPlayersAdd() {
        #expect(LyricsQuery(title: "Song - Remastered 2011", artist: "A").searchTitle == "Song")
        #expect(LyricsQuery(title: "Song (feat. Someone)", artist: "A").searchTitle == "Song")
        #expect(LyricsQuery(title: "Song [Live at Wembley]", artist: "A").searchTitle == "Song")
        #expect(LyricsQuery(title: "Song (Radio Edit) (feat. X)", artist: "A").searchTitle == "Song")
        #expect(LyricsQuery(title: "Bohemian Rhapsody", artist: "A").searchTitle == "Bohemian Rhapsody")
        #expect(LyricsQuery(title: "Me & You (Interlude)", artist: "A").searchTitle == "Me & You (Interlude)", "words that belong to the title stay")
        #expect(LyricsQuery(title: "Rock - Paper", artist: "A").searchTitle == "Rock - Paper")
    }

    @Test func cachesFindsLongerThanMisses() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let found = LyricsCacheEntry(lyrics: Lyrics(plain: "Words"), fetched: now.addingTimeInterval(-30 * 86_400))
        let miss = LyricsCacheEntry(lyrics: nil, fetched: now.addingTimeInterval(-4 * 86_400))
        #expect(found.isFresh(at: now))
        #expect(!miss.isFresh(at: now), "a miss is asked again after a few days")
        #expect(LyricsCacheEntry(lyrics: nil, fetched: now.addingTimeInterval(-86_400)).isFresh(at: now))
        let data = try #require(found.encoded())
        #expect(LyricsCacheEntry.decode(data) == found)
        #expect(LyricsCacheEntry.decode(Data("{}".utf8)) == nil)
    }
}

@Suite("Sing With Me: card")
struct LyricsPanelTests {
    /// A 14-inch MacBook Pro at its default scale: 1512×982, a 185-point notch, the Dock below.
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let visible = CGRect(x: 0, y: 70, width: 1512, height: 874)
    let notch = CGRect(x: 663.5, y: 944, width: 185, height: 38)

    func frame(_ preset: LyricsPreset, _ position: LyricsPosition = .underNotch) -> CGRect {
        LyricsGeometry.frame(for: LyricsPlacement(preset: preset), position: position, screen: screen, visible: visible, notch: notch)
    }

    @Test func theDefaultIsASmallCardUnderTheNotch() {
        let small = frame(.small)
        #expect(small.size == CGSize(width: 151, height: 68), "a tenth of the width, two or three lines tall")
        #expect(abs(small.midX - notch.midX) <= 1)
        #expect(small.maxY == 938, "just under the notch and the menu bar, never over them")
        #expect(LyricsPlacement(saved: nil).preset == .small)
        #expect(LyricsPlacement.standard.preset == .small)
    }

    @Test func noPresetCoversTheMenuBar() {
        for preset in LyricsPreset.allCases where preset != .custom {
            #expect(frame(preset).maxY <= visible.maxY, "\(preset)")
        }
        #expect(frame(.medium).width == 378)
        #expect(frame(.band).width == 1500)
        #expect(frame(.fullScreen) == visible)
    }

    @Test func aDraggedCardKeepsItsPlaceOnlyWhenFree() {
        let custom = LyricsPlacement(preset: .custom, frame: CGRect(x: 100, y: 500, width: 300, height: 90))
        let free = LyricsGeometry.frame(for: custom, position: .free, screen: screen, visible: visible, notch: notch)
        #expect(free == CGRect(x: 100, y: 500, width: 300, height: 90))
        let under = LyricsGeometry.frame(for: custom, position: .underNotch, screen: screen, visible: visible, notch: notch)
        #expect(under.size == CGSize(width: 300, height: 90), "under the notch, only its size counts")
        #expect(abs(under.midX - notch.midX) <= 1)
        let second = CGRect(x: 1512, y: -200, width: 1920, height: 1080)
        let there = LyricsGeometry.frame(for: custom, position: .free, screen: second, visible: second, notch: nil)
        #expect(there == CGRect(x: 1612, y: 300, width: 300, height: 90), "relative to its own display")
        let offscreen = LyricsPlacement(preset: .custom, frame: CGRect(x: 5_000, y: 5_000, width: 9_000, height: 10))
        let kept = LyricsGeometry.frame(for: offscreen, position: .free, screen: screen, visible: visible, notch: notch)
        #expect(kept == CGRect(x: 0, y: 938, width: 1512, height: 44), "too wide: the screen's width; too short: the minimum")
    }

    @Test func savesPlacements() {
        let custom = LyricsPlacement(preset: .custom, frame: CGRect(x: 10, y: 20, width: 500, height: 240))
        #expect(LyricsPlacement(saved: custom.saved) == custom)
        #expect(LyricsPlacement(saved: "medium") == LyricsPlacement(preset: .medium))
        #expect(LyricsPlacement(saved: "compact") == .standard, "the old presets are gone")
        #expect(LyricsPlacement(saved: "custom:1,2,nan,4") == .standard)
        #expect(LyricsPlacement(saved: "custom:1,2,-3,4") == .standard)
        #expect(LyricsPlacement(preset: .custom) == .standard, "custom needs a frame")
        #expect(LyricsPlacement(preset: .medium, frame: custom.frame).frame == nil)
        #expect(LyricsPlacement.savedVersion >= 2)
    }

    @Test func resizesFromAnyEdgeDownToTiny() {
        let bounds = LyricsGeometry.bounds(screen: screen, visible: visible)
        let start = CGRect(x: 400, y: 600, width: 600, height: 300)
        #expect(LyricsGeometry.resize(start, edges: .right, by: CGSize(width: 100, height: 50), within: bounds)
            == CGRect(x: 400, y: 600, width: 700, height: 300))
        #expect(LyricsGeometry.resize(start, edges: [.left, .bottom], by: CGSize(width: -50, height: -100), within: bounds)
            == CGRect(x: 350, y: 500, width: 650, height: 400))
        let tiny = LyricsGeometry.resize(start, edges: [.left, .top], by: CGSize(width: 900, height: -900), within: bounds)
        #expect(tiny == CGRect(x: 900, y: 600, width: 100, height: 44), "down to 100×44; the far edges stay")
        let huge = LyricsGeometry.resize(start, edges: [.top, .right], by: CGSize(width: 5_000, height: 5_000), within: bounds)
        #expect(huge.maxX == bounds.maxX)
        #expect(huge.maxY == screen.maxY, "dragged, it may reach the very top")
    }

    @Test func findsTheEdgeUnderThePointer() {
        let size = CGSize(width: 600, height: 300)
        #expect(LyricsGeometry.edges(at: CGPoint(x: 300, y: 150), in: size) == [])
        #expect(LyricsGeometry.edges(at: CGPoint(x: 2, y: 150), in: size) == .left)
        #expect(LyricsGeometry.edges(at: CGPoint(x: 300, y: 1), in: size) == .bottom)
        #expect(LyricsGeometry.edges(at: CGPoint(x: 2, y: 12), in: size) == [.left, .bottom])
        #expect(LyricsGeometry.edges(at: CGPoint(x: 590, y: 299), in: size) == [.right, .top])
        // A tiny card's corners don't swallow its middle.
        let tiny = CGSize(width: 100, height: 44)
        #expect(LyricsGeometry.edges(at: CGPoint(x: 2, y: 22), in: tiny) == .left)
        #expect(LyricsGeometry.edges(at: CGPoint(x: 50, y: 22), in: tiny) == [])
    }

    @Test func typedSizesKeepTheTopAndCentre() {
        let bounds = LyricsGeometry.bounds(screen: screen, visible: visible)
        let small = frame(.small)
        let sized = LyricsGeometry.sized(small, width: 301, height: 100, within: bounds)
        #expect(sized.midX == small.midX)
        #expect(sized.maxY == small.maxY)
        #expect(LyricsGeometry.sized(small, width: 10, height: 10, within: bounds).size == LyricsGeometry.minimumSize)
    }

    @Test func headerControlsStayOutOfTheCamera() throws {
        let band = CGRect(x: 0, y: 589, width: 1512, height: 393)
        let beside = LyricsHeaderLayout(panel: band, notch: notch)
        #expect(beside.topInset == 0)
        let gap = try #require(beside.gap)
        #expect(gap.lowerBound == 653.5)
        #expect(gap.upperBound == 858.5)
        #expect(beside.leadingWidth == 653.5)
        #expect(beside.trailingWidth == 1512 - 858.5)
        #expect(beside.height == 44)
        let tallNotch = CGRect(x: 663.5, y: 932, width: 185, height: 50)
        #expect(LyricsHeaderLayout(panel: band, notch: tallNotch).height == 50, "the words start below the camera")

        // A card no wider than the notch's surroundings: the header drops below the camera.
        let card = CGRect(x: 606, y: 762, width: 300, height: 220)
        let below = LyricsHeaderLayout(panel: card, notch: notch)
        #expect(below.gap == nil)
        #expect(below.topInset == 38)

        // Dragged below the notch, or on a display without one: no gap at all.
        #expect(LyricsHeaderLayout(panel: CGRect(x: 0, y: 200, width: 800, height: 400), notch: notch).gap == nil)
        #expect(LyricsHeaderLayout(panel: band, notch: nil) == LyricsHeaderLayout(topInset: 0, leadingWidth: 1512, trailingWidth: 1512, gap: nil))
        // Off to one side of the notch: no overlap.
        #expect(LyricsHeaderLayout(panel: CGRect(x: 900, y: 600, width: 500, height: 382), notch: notch).gap == nil)
    }

    @Test func hoverButtonsAvoidTheCamera() {
        #expect(LyricsControls.atTop(panel: frame(.small), notch: notch), "under the notch: the top corner is free")
        let underCamera = CGRect(x: 640, y: 900, width: 200, height: 82)
        #expect(!LyricsControls.atTop(panel: underCamera, notch: notch), "dragged up behind the camera: the bottom corner")
        #expect(LyricsControls.atTop(panel: underCamera, notch: nil))
    }

    @Test func smallCardsShowFewerBiggerLines() {
        let small = LyricsTypography.layout(panel: CGSize(width: 151, height: 68), lines: .three, scale: 1)
        #expect(small.lines == 3)
        #expect(small.fontSize >= 10 && small.fontSize <= 13)
        let tiny = LyricsTypography.layout(panel: CGSize(width: 100, height: 44), lines: .three, scale: 1)
        #expect(tiny.lines == 2, "a line is dropped rather than shown too small")
        #expect(tiny.fontSize >= 10)
        let one = LyricsTypography.layout(panel: CGSize(width: 151, height: 68), lines: .one, scale: 1)
        #expect(one.lines == 1)
        #expect(one.fontSize >= small.fontSize)
        let wideOne = LyricsTypography.layout(panel: CGSize(width: 500, height: 68), lines: .one, scale: 1)
        let wideThree = LyricsTypography.layout(panel: CGSize(width: 500, height: 68), lines: .three, scale: 1)
        #expect(wideOne.fontSize > wideThree.fontSize, "one line fills the card")
        let big = LyricsTypography.layout(panel: CGSize(width: 1512, height: 874), lines: .five, scale: 1)
        #expect(big.fontSize == 64, "never bigger than 64 before the multiplier")
        let all = LyricsTypography.layout(panel: CGSize(width: 600, height: 300), lines: .all, scale: 1)
        #expect(all.lines == nil)
        let scaled = LyricsTypography.layout(panel: CGSize(width: 600, height: 300), lines: .two, scale: 1.5)
        let plain = LyricsTypography.layout(panel: CGSize(width: 600, height: 300), lines: .two, scale: 1)
        #expect(abs(scaled.fontSize - plain.fontSize * 1.5) <= 1)
        #expect(LyricsTypography.layout(panel: CGSize(width: 600, height: 300), lines: .two, scale: .nan) == plain)
        #expect(!LyricsTypography.showsHeader(panel: CGSize(width: 151, height: 68)), "a small card has no header")
        #expect(LyricsTypography.showsHeader(panel: CGSize(width: 600, height: 300)))
    }

    @Test func linesAroundTheCurrentOne() {
        #expect(LyricsLineCount.window(count: 1, around: 4, total: 10) == 4..<5)
        #expect(LyricsLineCount.window(count: 2, around: 4, total: 10) == 4..<6, "the line and the next")
        #expect(LyricsLineCount.window(count: 3, around: 4, total: 10) == 3..<6, "one sung, the line, one coming")
        #expect(LyricsLineCount.window(count: 5, around: 4, total: 10) == 2..<7)
        #expect(LyricsLineCount.window(count: 3, around: nil, total: 10) == 0..<3, "before the first line")
        #expect(LyricsLineCount.window(count: 3, around: 9, total: 10) == 7..<10, "kept inside the song")
        #expect(LyricsLineCount.window(count: 5, around: 0, total: 2) == 0..<2)
        #expect(LyricsLineCount.window(count: 3, around: 0, total: 0).isEmpty)
    }

    @Test func offsetsMoveInTenths() {
        #expect(LyricsOffset.stepped(0, by: 1) == 0.1)
        #expect(LyricsOffset.stepped(0.1, by: 2) == 0.3, "no 0.30000000000000004")
        #expect(LyricsOffset.stepped(0, by: -3) == -0.3)
        #expect(LyricsOffset.stepped(9.95, by: 5) == 10)
        #expect(LyricsOffset.stepped(-10, by: -1) == -10)
        #expect(LyricsOffset.label(0) == "On time")
        #expect(LyricsOffset.label(0.3) == "0.3 s sooner")
        #expect(LyricsOffset.label(-1.2) == "1.2 s later")
        #expect(LyricsOffset.label(0.04) == "On time")
    }

    @Test func lyricsLinks() {
        #expect(LinkValue.lyricsAction(nil) == .toggle)
        #expect(LinkValue.lyricsAction("open") == .open)
        #expect(LinkValue.lyricsAction("Close") == .close)
        #expect(LinkValue.lyricsAction("toggle") == .toggle)
        #expect(LinkValue.lyricsAction("delete") == nil)
    }
}

@Suite("Sing With Me: look and highlight")
struct LyricsAppearanceTests {
    @Test func defaultsAreASmallFrostedCardThatFillsLikeSpotify() {
        let look = LyricsAppearance.standard
        #expect(look.highlight == .fill)
        #expect(look.position == .underNotch)
        #expect(look.lines == .three)
        #expect(abs(look.otherLinesOpacity - 0.38) < 0.01, "other lines clearly dimmer than the one sung")
        #expect(look.resolvedCurrentColor == .white)
        #expect(look.blur > 0 && look.opacity > 0)
    }

    @Test func savesAndReadsBack() throws {
        var look = LyricsAppearance()
        look.blur = 1
        look.background = .custom
        look.customColor = LyricsColor(red: 0.9, green: 0.9, blue: 0.8)
        look.currentColor = LyricsColor(red: 1, green: 0.8, blue: 0)
        look.alignment = .right
        look.lines = .all
        look.highlight = .line
        look.lineAnimation = .fade
        look.position = .free
        look.border = true
        #expect(LyricsAppearance.decode(look.encoded()) == look)
    }

    @Test func badValuesFallBackToTheDefaults() {
        #expect(LyricsAppearance.decode(nil) == .standard)
        #expect(LyricsAppearance.decode(Data("not json".utf8)) == .standard)
        #expect(LyricsAppearance.decode(Data("{}".utf8)) == .standard, "an old value with nothing in it")
        let mixed = LyricsAppearance.decode(Data(#"{"blur":7,"opacity":-1,"weight":"ultra","cornerRadius":99,"lines":"two","dimming":"lots"}"#.utf8))
        #expect(mixed.blur == 1)
        #expect(mixed.opacity == 0)
        #expect(mixed.weight == .bold, "an unknown weight is the default")
        #expect(mixed.cornerRadius == 40)
        #expect(mixed.lines == .two, "the good values stay")
        #expect(mixed.dimming == LyricsAppearance.standard.dimming)
        var broken = LyricsAppearance()
        broken.textScale = .infinity
        #expect(broken.clamped().textScale == 1)
        #expect(LyricsColor(red: 2, green: -1, blue: .nan).red == 1)
    }

    @Test func wordsTurnDarkOnALightBackground() {
        var look = LyricsAppearance()
        look.background = .light
        #expect(look.resolvedCurrentColor == .black)
        look.opacity = 0.1
        #expect(look.resolvedCurrentColor == .white, "barely there, it's the desktop behind that counts")
        look.opacity = 1
        look.background = .custom
        look.customColor = LyricsColor(red: 0.1, green: 0.1, blue: 0.3)
        #expect(look.resolvedCurrentColor == .white)
        look.currentColor = LyricsColor(red: 1, green: 0, blue: 0)
        #expect(look.resolvedCurrentColor == LyricsColor(red: 1, green: 0, blue: 0), "a chosen colour wins")
    }

    @Test func clearCardsKeepAShadowOnTheWords() {
        var look = LyricsAppearance()
        look.shadow = false
        #expect(!look.needsTextShadow)
        look.blur = 0
        look.opacity = 0
        #expect(look.needsTextShadow, "floating words stay readable")
        #expect(LyricsAppearance().fadeReach > 0)
        look.edgeFade = 0
        #expect(look.fadeReach == 0)
    }

    @Test func theLineFillsFromItsStartToTheNext() throws {
        let lyrics = try #require(Lyrics(lrc: "[00:10.00] First\n[00:14.00] Second\n[00:20.00]\n[00:24.00] Last"))
        let half = try #require(LyricsTiming.fill(lyrics, position: 12, rate: 1, isPlaying: true, offset: 0, duration: 200))
        #expect(half == LyricsFill(index: 0, progress: 0.5, remaining: 2))
        let paused = try #require(LyricsTiming.fill(lyrics, position: 12, rate: 1, isPlaying: false, offset: 0, duration: 200))
        #expect(paused.remaining == nil, "paused, the fill stays where it is")
        #expect(paused.progress == 0.5)
        let fast = try #require(LyricsTiming.fill(lyrics, position: 12, rate: 2, isPlaying: true, offset: 0, duration: 200))
        #expect(fast.remaining == 1)
        #expect(LyricsTiming.fill(lyrics, position: 5, rate: 1, isPlaying: true, offset: 0, duration: 200) == nil, "before the first line")
        #expect(LyricsTiming.fill(lyrics, position: 21, rate: 1, isPlaying: true, offset: 0, duration: 200) == nil, "a break doesn't fill")
        let last = try #require(LyricsTiming.fill(lyrics, position: 24, rate: 1, isPlaying: true, offset: 0, duration: 200))
        #expect(last.remaining == 8, "the last line fills over a few seconds, not the rest of the song")
        let sooner = try #require(LyricsTiming.fill(lyrics, position: 11, rate: 1, isPlaying: true, offset: 1, duration: 200))
        #expect(sooner.progress == 0.5, "the offset moves the fill with the words")
    }

    @Test func aRunningFillIsLeftAloneWhenTheSongAgrees() {
        let planned = LyricsFill(index: 3, progress: 0.2, remaining: 4)
        #expect(abs(planned.progress(after: 2) - 0.6) < 1e-9)
        #expect(planned.progress(after: 99) == 1)
        #expect(planned.agrees(with: LyricsFill(index: 3, progress: 0.62, remaining: 1.9), after: 2, lineLength: 5))
        #expect(!planned.agrees(with: LyricsFill(index: 3, progress: 0.9, remaining: 0.5), after: 2, lineLength: 5), "a seek")
        #expect(!planned.agrees(with: LyricsFill(index: 3, progress: 0.6, remaining: nil), after: 2, lineLength: 5), "a pause")
        #expect(!planned.agrees(with: LyricsFill(index: 4, progress: 0, remaining: 3), after: 2, lineLength: 5))
    }

    @Test func aPositionWithoutATimeStillMoves() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = Data(#"{"type":"data","diff":false,"payload":{"title":"Song","artist":"Artist","playing":true,"elapsedTime":30,"duration":200}}"#.utf8)
        let info = try #require(NowPlaying.applying(line, to: nil, now: now))
        #expect(info.timestamp == now, "taken as of when it arrived")
        #expect(info.position(at: now.addingTimeInterval(5)) == 35, "so the lyrics follow the song")
        let stamped = Data(#"{"type":"data","diff":false,"payload":{"title":"Song","artist":"Artist","playing":true,"elapsedTime":30,"timestamp":"2027-01-15T07:59:58Z"}}"#.utf8)
        #expect(try #require(NowPlaying.applying(stamped, to: nil, now: now)).timestamp == now.addingTimeInterval(-2), "a real time is kept")
    }
}
