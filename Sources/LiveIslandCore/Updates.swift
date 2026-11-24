import CryptoKit
import Foundation

/// A version like "1.2.0", or a tag like "v1.2.0", compared number by number, so 1.10 comes
/// after 1.9 and 1.2 is the same as 1.2.0. A pre-release ("1.3.0-beta.2") comes before its
/// release, as in Semantic Versioning, so someone running a beta is offered the final 1.3.0.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    /// The identifiers after the "-", lowercased ("beta", "2"); empty for a release.
    public let prerelease: [String]
    public let description: String

    public var isPrerelease: Bool { !prerelease.isEmpty }

    public init?(_ text: String) {
        var string = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.first == "v" || string.first == "V" { string.removeFirst() }
        // Build metadata ("+abc") never changes which version is newer.
        let core = string.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let halves = core.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = (halves.first ?? "").split(separator: ".", omittingEmptySubsequences: false)
        let parsed = numbers.map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        var parts = parsed.map { $0! }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        var prerelease: [String] = []
        if halves.count == 2 {
            prerelease = halves[1].split(separator: ".", omittingEmptySubsequences: false).map { $0.lowercased() }
            guard prerelease.allSatisfy({ !$0.isEmpty }) else { return nil }
        }
        self.parts = parts
        self.prerelease = prerelease
        description = string
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        lhs.parts == rhs.parts && lhs.prerelease == rhs.prerelease
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        // Same numbers: a pre-release comes before the release itself.
        switch (lhs.isPrerelease, rhs.isPrerelease) {
        case (false, _): return false
        case (true, false): return true
        case (true, true): return precedes(lhs.prerelease, rhs.prerelease)
        }
    }

    /// Semantic Versioning's order for pre-releases: identifier by identifier, numbers by value
    /// and before words, and a shorter list first when the rest is the same ("beta" < "beta.2").
    private static func precedes(_ lhs: [String], _ rhs: [String]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.count < rhs.count
    }
}

/// A release on GitHub that LiveIsland can update to.
public struct AppRelease: Equatable, Sendable {
    public let version: AppVersion
    public let title: String
    /// What's new, from the release notes, without the install instructions.
    public let notes: String
    public let page: URL
    public let archive: URL
    public let checksum: URL?
    public let size: Int
}

/// Reads GitHub's answer for a repository's latest release.
public enum ReleaseFeed {
    /// The app's zip, attached to every release under exactly this name.
    public static let archiveName = "LiveIsland.zip"

    /// The release in a `releases/latest` answer, if it's a published version with the app's zip.
    public static func release(from json: Data) -> AppRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String, let version = AppVersion(tag),
              let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              let assets = object["assets"] as? [[String: Any]]
        else { return nil }
        func asset(_ name: String) -> (url: URL, size: Int)? {
            guard let asset = assets.first(where: { $0["name"] as? String == name }),
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
                  url.scheme == "https"
            else { return nil }
            return (url, asset["size"] as? Int ?? 0)
        }
        guard let archive = asset(archiveName) else { return nil }
        let title = (object["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "LiveIsland \(version)"
        return AppRelease(version: version, title: title, notes: summary(of: object["body"] as? String ?? ""),
                          page: page, archive: archive.url, checksum: asset(archiveName + ".sha256")?.url, size: archive.size)
    }

    /// Whether the release is newer than the version running now.
    public static func isUpdate(_ release: AppRelease, over current: String) -> Bool {
        guard let current = AppVersion(current) else { return true }
        return release.version > current
    }

    /// The SHA-256 in a `shasum -a 256` line for the archive, lowercased.
    public static func checksum(in text: String, for name: String = archiveName) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name else { continue }
            let hash = fields[0].lowercased()
            if hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    /// The notes worth showing in Settings: the release's own heading and everything from its
    /// install instructions on are left out.
    static func summary(of body: String) -> String {
        var lines: [Substring] = []
        // GitHub keeps notes with \r\n, which Swift counts as one character: split on any newline.
        for line in body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("**Install**") || trimmed.lowercased().hasPrefix("## install") { break }
            if trimmed.hasPrefix("# ") || trimmed.hasPrefix("## ") { continue }
            lines.append(line)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The SHA-256 of a file, read a piece at a time: the zip is several megabytes, and reading it
/// whole into memory (or on the main thread) would stall the app for nothing.
public enum FileDigest {
    public static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: max(1, chunkSize)), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Who must have signed a downloaded update. `codesign --verify` alone passes any intact
/// signature, ad hoc included, so a Developer ID build also asks for its own Team ID.
public enum UpdateSignature {
    /// A code signing requirement for the bundle signed by this Team ID through a Developer ID
    /// (or the Mac App Store) certificate, or nil when the ID isn't one, so nothing odd is ever
    /// pasted into the requirement's text.
    public static func requirement(teamID: String, bundleID: String) -> String? {
        let allowedID = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let allowedBundle = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard teamID.count == 10, teamID.unicodeScalars.allSatisfy(allowedID.contains),
              !bundleID.isEmpty, bundleID.unicodeScalars.allSatisfy({ $0.isASCII && allowedBundle.contains($0) })
        else { return nil }
        return #"identifier "\#(bundleID)" and anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
    }
}

/// How far a download has come, for the progress bar: GitHub tells the zip's size up front, so
/// the bar still fills when the server doesn't send a length.
public struct DownloadProgress: Equatable, Sendable {
    public let received: Int64
    public let expected: Int64

    public init(received: Int64, expected: Int64, promised: Int) {
        self.received = max(0, received)
        self.expected = expected > 0 ? expected : Int64(max(0, promised))
    }

    /// From 0 to 1, or nil when the size isn't known.
    public var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    /// Whether the bar would move enough to be worth drawing again: a whole percent, so a fast
    /// download doesn't redraw Settings hundreds of times a second.
    public func differsVisibly(from other: DownloadProgress?) -> Bool {
        guard let other else { return true }
        guard let now = fraction, let before = other.fraction else { return received != other.received }
        return Int(now * 100) != Int(before * 100)
    }
}
