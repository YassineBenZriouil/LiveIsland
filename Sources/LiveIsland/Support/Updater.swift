import AppKit
import LiveIslandCore
import os
import Security

private let log = Logger(subsystem: "com.aissam.liveisland", category: "updates")

/// Software updates from LiveIsland's GitHub releases, like macOS's own: it checks once a day
/// (unless turned off) and says what's new. Only when the person asks does it download the
/// new version, check it, put it in place of this one and relaunch.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(AppRelease)
        /// With how far it has come, once the first bytes arrive.
        case downloading(AppRelease, DownloadProgress?)
        case installing(AppRelease)
        /// The release stays when an install fails, so Update Now can try again and its page
        /// is still a click away.
        case failed(String, release: AppRelease?)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var checksAutomatically = false {
        didSet { if checksAutomatically != oldValue { schedule() } }
    }

    /// The repository whose releases LiveIsland updates from.
    static let feed = URL(string: "https://api.github.com/repos/charonova/LiveIsland/releases/latest")!
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// The newer version on offer: found by the last check, or kept after an install failed.
    var availableRelease: AppRelease? {
        switch state {
        case .available(let release): return release
        case .failed(_, let release): return release
        default: return nil
        }
    }

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    /// Whether Cancel would stop the update: only while downloading and checking the download,
    /// never once the new app is being put in place.
    var canCancel: Bool {
        if case .downloading = state { return true }
        return false
    }

    private var timer: Timer?
    private var firstCheck: DispatchWorkItem?
    private var download: Download?
    private var cancelRequested = false
    private let defaults = UserDefaults.standard
    private static let lastCheckKey = "lastUpdateCheck"

    func start() {
        lastChecked = defaults.object(forKey: Self.lastCheckKey) as? Date
        schedule()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        firstCheck?.cancel()
    }

    /// A minute after launch, then every few hours, it checks if a day has passed since the last time.
    private func schedule() {
        stop()
        guard checksAutomatically else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.checkIfDue() } }
        firstCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
        let timer = Timer(timeInterval: 3 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func checkIfDue() {
        guard checksAutomatically, !isBusy, availableRelease == nil,
              Date().timeIntervalSince(lastChecked ?? .distantPast) > 23 * 3600
        else { return }
        Task { await check() }
    }

    func check() async {
        guard !isBusy else { return }
        // A release already found stays on offer if this check fails.
        let known = availableRelease
        state = .checking
        do {
            var request = URLRequest(url: Self.feed, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("LiveIsland/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure("GitHub answered with error \(status). Try again later.") }
            lastChecked = Date()
            defaults.set(lastChecked, forKey: Self.lastCheckKey)
            if let release = ReleaseFeed.release(from: data), ReleaseFeed.isUpdate(release, over: currentVersion) {
                log.notice("LiveIsland \(release.version.description, privacy: .public) is available")
                state = .available(release)
            } else {
                state = .upToDate
            }
        } catch {
            log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(Self.describe(error), release: known)
        }
    }

    /// Downloads the release, makes sure it's the one promised, and relaunches into it.
    func install() async {
        guard !isBusy, let release = availableRelease else { return }
        cancelRequested = false
        state = .downloading(release, nil)
        do {
            let target = Bundle.main.bundleURL
            let parent = target.deletingLastPathComponent()
            guard FileManager.default.isWritableFile(atPath: parent.path) else {
                throw Failure("LiveIsland can't replace itself in \(parent.path). Download the new version from its release page instead.")
            }
            // Without a checksum there's no telling the zip is the one published, so it isn't installed.
            guard let checksumURL = release.checksum else {
                throw Failure("This release has no checksum to check the download against, so it can't be installed from here. Download it from its release page instead.")
            }
            // A folder on the same disk as the app, so the final move is quick.
            let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                     appropriateFor: target, create: true)
            do {
                try await install(release, in: folder, checksum: checksumURL, replacing: target)
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        } catch is CancellationError {
            log.notice("Update to \(release.version.description, privacy: .public) cancelled")
            state = .available(release)
        } catch {
            log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            state = .failed(Self.describe(error), release: release)
        }
        download = nil
    }

    /// Stops the download; the release stays on offer.
    func cancel() {
        guard canCancel else { return }
        cancelRequested = true
        download?.cancel()
    }

    private func install(_ release: AppRelease, in folder: URL, checksum checksumURL: URL, replacing target: URL) async throws {
        let zip = folder.appendingPathComponent(ReleaseFeed.archiveName)
        let download = Download(to: zip) { [weak self] received, expected in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.report(received: received, expected: expected, of: release) }
            }
        }
        self.download = download
        try checkCancelled()
        try await download.run(release.archive)
        try checkCancelled()

        let (data, response) = try await URLSession.shared.data(from: checksumURL)
        try checkCancelled()
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let expected = ReleaseFeed.checksum(in: String(decoding: data, as: UTF8.self))
        else { throw Failure("The release's checksum couldn't be read, so the download wasn't installed.") }
        // A piece at a time and off the main thread, so Settings stays responsive.
        let actual = try await Task.detached(priority: .utility) { try FileDigest.sha256(of: zip) }.value
        try checkCancelled()
        guard actual == expected else { throw Failure("The download doesn't match its checksum, so it wasn't installed.") }

        state = .installing(release)
        let unpacked = folder.appendingPathComponent("unpacked")
        guard try await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
            throw Failure("The download couldn't be unpacked.")
        }
        let app = unpacked.appendingPathComponent("LiveIsland.app")
        // It must be LiveIsland, the version promised, with an intact signature.
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
              version == release.version
        else { throw Failure("The download isn't LiveIsland \(release.version), so it wasn't installed.") }
        guard try await ProcessRunner.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", app.path]).status == 0 else {
            throw Failure("The new version's signature is broken, so it wasn't installed.")
        }
        // A Developer ID build only accepts an update signed by the same team. An ad-hoc build
        // has no team to compare, and relies on the checksum above.
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aissam.liveisland"
        let sameTeam = await Task.detached(priority: .utility) { () -> Bool in
            guard let team = CodeSignature.runningTeamID() else { return true }
            guard let requirement = UpdateSignature.requirement(teamID: team, bundleID: bundleID) else { return false }
            return CodeSignature.app(at: app, satisfies: requirement)
        }.value
        guard sameTeam else {
            throw Failure("The new version isn't signed by LiveIsland's developer, so it wasn't installed.")
        }
        log.notice("Installing LiveIsland \(release.version.description, privacy: .public)")
        try relaunch(replacing: target, with: app, leftovers: folder)
    }

    private func checkCancelled() throws {
        if cancelRequested { throw CancellationError() }
    }

    /// Moves the bar, at most once per percent, and only while that download is still on.
    private func report(received: Int64, expected: Int64, of release: AppRelease) {
        guard case .downloading(let current, let previous) = state, current == release else { return }
        let progress = DownloadProgress(received: received, expected: expected, promised: release.size)
        if progress.differsVisibly(from: previous) { state = .downloading(release, progress) }
    }

    /// A few lines of shell, left running after LiveIsland quits: they wait for it to end, swap
    /// the apps (the old one stays until the new one is in place, and comes back if the move
    /// fails), and open whichever is there.
    private func relaunch(replacing target: URL, with app: URL, leftovers: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        previous="$2.previous"
        rm -rf "$previous"
        if mv "$2" "$previous"; then
            if mv "$3" "$2"; then rm -rf "$previous"; else mv "$previous" "$2"; fi
        fi
        rm -rf "$4"
        open "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "liveisland-update", String(getpid()), target.path, app.path, leftovers.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        NSApp.terminate(nil)
    }

    /// The server answered the download with an error page instead of the zip.
    struct DownloadFailure: LocalizedError {
        var errorDescription: String? { "The download didn't finish. Try again." }
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? Failure { return failure.message }
        if (error as? URLError)?.code == .notConnectedToInternet { return "You're offline. Connect to the internet and try again." }
        return error.localizedDescription
    }
}

/// One download, with its progress: `URLSession.download(from:)` reports none and can't be
/// stopped from Settings. Its session lives only as long as the download.
private final class Download: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64, Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDownloadTask?
    private var finishError: Error?
    private var cancelled = false

    init(to destination: URL, onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func run(_ url: URL) async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: queue)
        // The session holds its delegate until it's invalidated.
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancelled {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            let task = session.downloadTask(with: URLRequest(url: url, timeoutInterval: 60))
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    /// The downloaded file is deleted once this returns, so it moves now.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        var error: Error?
        if (downloadTask.response as? HTTPURLResponse)?.statusCode != 200 {
            error = Updater.DownloadFailure()
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch let moveError {
                error = moveError
            }
        }
        lock.lock()
        finishError = error
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let failure: Error? = cancelled ? CancellationError() : (error ?? finishError)
        lock.unlock()
        if let failure { continuation?.resume(throwing: failure) } else { continuation?.resume() }
    }
}

/// The running app's signature and a downloaded one's, read with the Security framework.
private enum CodeSignature {
    /// The Team ID LiveIsland is signed with, or nil for an ad-hoc build.
    static func runningTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any]
        else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether the app has a valid signature, nested code included, that meets the requirement.
    static func app(at url: URL, satisfies text: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }
}
