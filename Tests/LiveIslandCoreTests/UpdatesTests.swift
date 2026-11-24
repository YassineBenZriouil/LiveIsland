import Foundation
import Testing
@testable import LiveIslandCore

/// GitHub's `releases/latest` answer, trimmed to the fields LiveIsland reads.
private func releaseJSON(tag: String = "v1.3.0", draft: Bool = false, prerelease: Bool = false,
                         assets: [String] = ["LiveIsland.zip", "LiveIsland.zip.sha256"]) -> Data {
    let list = assets.map { name in
        #"{"name":"\#(name)","size":3456789,"browser_download_url":"https://github.com/charonova/LiveIsland/releases/download/\#(tag)/\#(name)"}"#
    }.joined(separator: ",")
    let body = #"## LiveIsland 1.3.0\r\n\r\n**New**\r\n- **Something**: it's nice.\r\n\r\n**Install** (macOS 14+):\r\n\r\n```bash\r\ncurl …\r\n```"#
    return Data(#"{"tag_name":"\#(tag)","name":"LiveIsland 1.3.0","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"https://github.com/charonova/LiveIsland/releases/tag/\#(tag)","body":"\#(body)","assets":[\#(list)]}"#.utf8)
}

@Suite("Software updates")
struct UpdatesTests {
    @Test func comparesVersionsNumberByNumber() {
        #expect(AppVersion("1.10.0")! > AppVersion("1.9.3")!)
        #expect(AppVersion("v1.2.0")! == AppVersion("1.2")!)
        #expect(AppVersion("1.2.1")! > AppVersion("1.2")!)
        #expect(AppVersion("2")! > AppVersion("1.99.99")!)
        #expect(!(AppVersion("1.2.0")! < AppVersion("1.2.0")!))
        #expect(AppVersion("v1.2.0")!.description == "1.2.0")
    }

    @Test func putsAPreReleaseBeforeItsRelease() {
        #expect(AppVersion("1.3.0-beta")! < AppVersion("1.3.0")!)
        #expect(AppVersion("1.3.0-beta")! != AppVersion("1.3.0")!)
        #expect(AppVersion("1.3.0-beta")! > AppVersion("1.2.9")!)
        #expect(AppVersion("1.3-beta")! == AppVersion("v1.3.0-BETA")!)
        #expect(AppVersion("1.3.0-alpha")! < AppVersion("1.3.0-beta")!)
        #expect(AppVersion("1.3.0-beta")! < AppVersion("1.3.0-beta.2")!)
        #expect(AppVersion("1.3.0-beta.2")! < AppVersion("1.3.0-beta.10")!, "numbers by value")
        #expect(AppVersion("1.3.0-1")! < AppVersion("1.3.0-alpha")!, "numbers before words")
        #expect(AppVersion("1.3.0+build.5")! == AppVersion("1.3.0")!, "build metadata doesn't count")
        #expect(AppVersion("1.3.0-beta")!.isPrerelease)
        #expect(!AppVersion("1.3.0")!.isPrerelease)
    }

    @Test func offersTheReleaseToSomeoneOnItsBeta() throws {
        let release = try #require(ReleaseFeed.release(from: releaseJSON()))
        #expect(ReleaseFeed.isUpdate(release, over: "1.3.0-beta"))
        #expect(ReleaseFeed.isUpdate(release, over: "1.3.0-rc.1"))
        #expect(!ReleaseFeed.isUpdate(release, over: "1.3.1-beta"))
    }

    @Test func rejectsWhatIsntAVersion() {
        #expect(AppVersion("1.3.0-") == nil)
        #expect(AppVersion("1.3.0-beta..1") == nil)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("1.-2") == nil)
    }

    @Test func readsTheLatestRelease() throws {
        let release = try #require(ReleaseFeed.release(from: releaseJSON()))
        #expect(release.version == AppVersion("1.3.0")!)
        #expect(release.title == "LiveIsland 1.3.0")
        #expect(release.archive.absoluteString == "https://github.com/charonova/LiveIsland/releases/download/v1.3.0/LiveIsland.zip")
        #expect(release.checksum?.lastPathComponent == "LiveIsland.zip.sha256")
        #expect(release.size == 3_456_789)
        #expect(release.page.absoluteString.hasSuffix("/releases/tag/v1.3.0"))
    }

    @Test func keepsOnlyWhatsNewInTheNotes() throws {
        let release = try #require(ReleaseFeed.release(from: releaseJSON()))
        #expect(release.notes.hasPrefix("**New**"))
        #expect(release.notes.contains("Something"))
        #expect(!release.notes.contains("curl"), "the install instructions are left out")
        #expect(!release.notes.contains("## LiveIsland"), "and so is the heading")
    }

    @Test func skipsReleasesItCantInstall() {
        #expect(ReleaseFeed.release(from: releaseJSON(draft: true)) == nil)
        #expect(ReleaseFeed.release(from: releaseJSON(prerelease: true)) == nil)
        #expect(ReleaseFeed.release(from: releaseJSON(assets: ["LiveIsland.app.zip"])) == nil, "no zip under the expected name")
        #expect(ReleaseFeed.release(from: releaseJSON(tag: "nightly")) == nil)
        #expect(ReleaseFeed.release(from: Data("{\"message\":\"Not Found\"}".utf8)) == nil)
        #expect(ReleaseFeed.release(from: Data("nope".utf8)) == nil)
    }

    @Test func offersOnlyNewerVersions() throws {
        let release = try #require(ReleaseFeed.release(from: releaseJSON()))
        #expect(ReleaseFeed.isUpdate(release, over: "1.2.0"))
        #expect(!ReleaseFeed.isUpdate(release, over: "1.3.0"))
        #expect(!ReleaseFeed.isUpdate(release, over: "1.4"))
    }

    @Test func readsTheChecksumFile() {
        let hash = String(repeating: "ab", count: 32)
        #expect(ReleaseFeed.checksum(in: "\(hash)  LiveIsland.zip\n") == hash)
        #expect(ReleaseFeed.checksum(in: "\(hash.uppercased()) *LiveIsland.zip") == hash, "binary-mode marker, any case")
        #expect(ReleaseFeed.checksum(in: "\(hash)  Other.zip") == nil)
        #expect(ReleaseFeed.checksum(in: "1234  LiveIsland.zip") == nil)
    }

    @Test func noticesAReleaseWithoutAChecksum() throws {
        let release = try #require(ReleaseFeed.release(from: releaseJSON(assets: ["LiveIsland.zip"])))
        #expect(release.checksum == nil, "it's still shown, but Update Now refuses it")
    }

    @Test func hashesAFileAPieceAtATime() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UpdatesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("LiveIsland.zip")
        try Data("abc".utf8).write(to: file)
        let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(try FileDigest.sha256(of: file) == abc)
        #expect(try FileDigest.sha256(of: file, chunkSize: 1) == abc, "the same, read a byte at a time")

        let big = Data((0..<300_000).map { UInt8($0 % 251) })
        try big.write(to: file)
        let whole = try FileDigest.sha256(of: file)
        #expect(try FileDigest.sha256(of: file, chunkSize: 4096) == whole)
        #expect(try FileDigest.sha256(of: file, chunkSize: 299_999) == whole)

        try Data().write(to: file)
        #expect(try FileDigest.sha256(of: file) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(throws: (any Error).self) { try FileDigest.sha256(of: folder.appendingPathComponent("missing.zip")) }
    }

    @Test func asksForTheSameTeam() {
        #expect(UpdateSignature.requirement(teamID: "AB12CD34EF", bundleID: "com.aissam.liveisland")
                == #"identifier "com.aissam.liveisland" and anchor apple generic and certificate leaf[subject.OU] = "AB12CD34EF""#)
        #expect(UpdateSignature.requirement(teamID: "ab12cd34ef", bundleID: "com.aissam.liveisland") == nil)
        #expect(UpdateSignature.requirement(teamID: "AB12CD34E", bundleID: "com.aissam.liveisland") == nil)
        #expect(UpdateSignature.requirement(teamID: #"AB12" or 1"#, bundleID: "com.aissam.liveisland") == nil)
        #expect(UpdateSignature.requirement(teamID: "AB12CD34EF", bundleID: #"x" or anchor"#) == nil)
        #expect(UpdateSignature.requirement(teamID: "AB12CD34EF", bundleID: "") == nil)
    }

    @Test func measuresTheDownload() {
        let start = DownloadProgress(received: 0, expected: -1, promised: 3_456_789)
        #expect(start.expected == 3_456_789, "GitHub's size, when the server sends no length")
        #expect(start.fraction == 0)
        let half = DownloadProgress(received: 1_728_395, expected: 3_456_789, promised: 3_456_789)
        #expect(half.fraction! > 0.49 && half.fraction! < 0.51)
        #expect(DownloadProgress(received: 5_000_000, expected: 3_456_789, promised: 0).fraction == 1)
        #expect(DownloadProgress(received: 10, expected: 0, promised: 0).fraction == nil)

        #expect(start.differsVisibly(from: nil))
        #expect(!DownloadProgress(received: 100, expected: 3_456_789, promised: 0).differsVisibly(from: start), "under a percent")
        #expect(half.differsVisibly(from: start))
        let unknown = DownloadProgress(received: 10, expected: 0, promised: 0)
        #expect(DownloadProgress(received: 20, expected: 0, promised: 0).differsVisibly(from: unknown))
    }
}
