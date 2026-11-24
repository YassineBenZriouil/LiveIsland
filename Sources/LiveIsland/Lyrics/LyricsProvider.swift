import Foundation
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "lyrics")

/// Lyrics from LRCLIB, kept on disk so each song is asked about once. It sends only what
/// `LyricsQuery` holds (title, artist, album, length), with a plain user agent, and nothing
/// when the answer is already on disk. Network work runs off the main thread.
final class LyricsProvider: Sendable {
    enum Answer: Equatable, Sendable {
        case found(Lyrics)
        /// LRCLIB has nothing for this song.
        case missing
        /// Offline, a timeout, or LRCLIB having trouble: nothing is saved, so it's asked again later.
        case failed
    }

    private let folder: URL
    private let session: URLSession

    init(folder: URL = LyricsProvider.defaultFolder) {
        self.folder = folder
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["User-Agent": LRCLib.userAgent, "Accept": "application/json"]
        session = URLSession(configuration: configuration)
    }

    static var defaultFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("LiveIsland/lyrics", isDirectory: true)
    }

    /// What's on disk for the song, if it's still fresh. Reads one small file.
    func cached(_ query: LyricsQuery, now: Date = Date()) -> Answer? {
        let file = folder.appendingPathComponent(query.fileName)
        guard let data = try? Data(contentsOf: file), let entry = LyricsCacheEntry.decode(data), entry.isFresh(at: now) else { return nil }
        return entry.lyrics.map(Answer.found) ?? .missing
    }

    /// The exact lookup, then the search when that finds nothing; the answer is saved, misses
    /// included (they're asked again after a few days).
    func fetch(_ query: LyricsQuery) async -> Answer {
        var answer: Answer?
        if let url = LRCLib.getURL(for: query) {
            switch await load(url) {
            case .success(let data):
                if let lyrics = LRCLib.decodeRecord(data)?.lyrics { answer = .found(lyrics) }
            case .notFound: break
            case .failure: return .failed
            }
        }
        if answer == nil, let url = LRCLib.searchURL(for: query) {
            switch await load(url) {
            case .success(let data):
                let match = LRCLib.bestMatch(in: LRCLib.decodeSearch(data), duration: query.duration)
                answer = match?.lyrics.map(Answer.found) ?? .missing
            case .notFound: answer = .missing
            case .failure: return .failed
            }
        }
        let result = answer ?? .missing
        save(result, for: query)
        return result
    }

    private enum Load {
        case success(Data)
        case notFound
        case failure
    }

    private func load(_ url: URL) async -> Load {
        do {
            let (data, response) = try await session.data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 { return .notFound }
            guard (200..<300).contains(status) else {
                log.error("LRCLIB answered \(status, privacy: .public)")
                return .failure
            }
            return .success(data)
        } catch {
            log.error("LRCLIB unreachable: \(error.localizedDescription, privacy: .public)")
            return .failure
        }
    }

    private func save(_ answer: Answer, for query: LyricsQuery) {
        let lyrics: Lyrics?
        switch answer {
        case .found(let found): lyrics = found
        case .missing: lyrics = nil
        case .failed: return
        }
        guard let data = LyricsCacheEntry(lyrics: lyrics, fetched: Date()).encoded() else { return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(query.fileName), options: .atomic)
        } catch {
            log.error("Couldn't save lyrics: \(error.localizedDescription, privacy: .public)")
        }
    }
}
