import AppKit
import Foundation
import SolStreamLogging

/// Keeps SolStream up to date from the repository's GitHub releases, by the
/// contract in docs/updates.md.
///
/// Quiet by design. It checks a minute after launch and then once a day,
/// downloads and verifies what it finds while nothing is streaming, and then
/// waits: an update is announced in Settings and on the connect window, and
/// installed only when the person presses the button -- never in the middle of
/// a stream, and never with a dialog that was not asked for.
///
/// While the repository is private, GitHub answers 404 to anyone without a
/// token, which this reads as "nothing published yet" and says nothing about.
/// `SOLSTREAM_GITHUB_TOKEN` in the environment lets a developer test against
/// the private releases; it is read from there on every request, sent only to
/// api.github.com, and never stored or logged.
@MainActor
final class Updater {
    /// Nameable from anywhere, so the app delegate and the connect window --
    /// which AppKit calls on the main thread without saying so to the
    /// compiler -- can reach it; made, like everything it does, on the main
    /// actor, where its first use always is.
    nonisolated static let shared: Updater = MainActor.assumeIsolated { Updater() }

    /// Posted on every change of state, and when streaming starts or stops.
    nonisolated static let didChange = Notification.Name("SolStream.updaterChanged")

    enum State: Equatable {
        /// Nothing checked since launch; `lastCheck` says when it last was.
        case idle
        case checking
        case upToDate
        /// Found, and not yet downloaded: a stream is open, or this copy
        /// cannot replace itself.
        case available(String)
        /// A fraction from 0 to 1, or nil until the size is known.
        case downloading(String, Double?)
        /// Downloaded and verified, waiting for the person.
        case ready(String)
        /// The person asked for it during a stream; it goes in when the stream
        /// closes.
        case waitingForStream(String)
        case installing(String)
        /// In place, but a stream opened while it went in: this copy restarts
        /// into it when the stream closes, not in the middle of it.
        case installed(String)
        /// Downloaded, but this copy cannot replace itself; the download can
        /// be shown instead.
        case manualInstall(String, reason: String)
        case failed(String)
    }

    enum CheckOutcome: Equatable {
        /// 404: nothing published that this client can see.
        case nothingVisible
        case upToDate(latest: String)
        case newer(Release)
    }

    private enum Key {
        static let automatic = "SolStream.update.automatic"
        static let lastCheck = "SolStream.update.lastCheck"
        static let lastResult = "SolStream.update.lastResult"
        static let replacedBundle = "SolStream.update.replacedBundle"
    }

    static let launchDelay: TimeInterval = 60
    static let interval: TimeInterval = 24 * 60 * 60

    var state: State = .idle {
        didSet { if state != oldValue { announce() } }
    }

    /// What this copy says it is, or what SOLSTREAM_PRETEND_VERSION says.
    let currentVersion: String
    let isPretending: Bool
    /// What the bundle really is, pretend or not. An install refuses anything
    /// not strictly newer than this, so a check must not offer it either.
    let builtVersion: String
    /// The bundle an install replaces: nil for a build run outside one, which
    /// can still check but never installs over itself.
    let installTarget: URL?

    /// Set by the app delegate. Nothing downloads, installs or restarts while
    /// it is true.
    var isStreaming = false {
        didSet {
            guard isStreaming != oldValue else { return }
            announce()
            if isStreaming {
                // A download already under way stops as well: it would share
                // the uplink with the stream. It starts again when the stream
                // closes.
                zipFetch?.cancel()
                return
            }
            switch state {
            case .waitingForStream(let version):
                if let downloaded, downloaded.version == version {
                    install(version: version, zip: downloaded.zip, sha256: downloaded.sha256)
                }
            case .installed(let version):
                restart(into: version)
            case .available where installTarget != nil:
                Task { await download() }
            default:
                break
            }
        }
    }

    var checksAutomatically: Bool {
        get { defaults.object(forKey: Key.automatic) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Key.automatic)
            Log.info("[update] automatic checks \(newValue ? "on" : "off")")
            announce()
        }
    }

    /// The last check that got an answer from GitHub. A failed one leaves it
    /// alone, so the hourly timer keeps trying until one gets through.
    var lastCheck: Date? { defaults.object(forKey: Key.lastCheck) as? Date }
    /// "upToDate", "available <version>" or "failed": what the last check found.
    var lastResult: String? { defaults.string(forKey: Key.lastResult) }

    /// Seams for the tests, which must never relaunch or quit the test runner,
    /// or open Finder.
    var relaunch: (URL) throws -> Void = UpdateInstaller.relaunch
    var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    var showInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    private let defaults: UserDefaults
    private let transport: UpdateTransport
    private let environment: [String: String]
    private let publicKey: String
    private let downloadsFolder: URL
    /// Where "Show download" puts the archive: the person's Downloads.
    private let revealFolder: URL?
    private(set) var offered: Release?
    /// The archive and its line in the signed sums, which the installer
    /// hashes it against again: it waits here for as long as the person
    /// takes, and anything running as them can write where it waits.
    private(set) var downloaded: (version: String, zip: URL, sha256: String)?
    /// The archive's own fetch, cancelled when a stream opens.
    private var zipFetch: Task<UpdateTransport.Response, Error>?
    private var timers: [Timer] = []
    /// When this run last asked GitHub, so the check a minute after launch is
    /// skipped if somebody pressed Check now first.
    private var askedThisRun: Date?

    init(defaults: UserDefaults = .standard,
         configuration: URLSessionConfiguration = UpdateTransport.defaultConfiguration(),
         environment: [String: String] = ProcessInfo.processInfo.environment,
         bundle: Bundle = .main,
         installTarget: URL? = Updater.installableBundle(.main),
         publicKey: String = UpdateSignature.productionKey,
         downloadsFolder: URL = Updater.defaultDownloadsFolder,
         revealFolder: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first) {
        self.defaults = defaults
        self.transport = UpdateTransport(configuration: configuration)
        self.environment = environment
        self.publicKey = publicKey
        self.installTarget = installTarget
        self.downloadsFolder = downloadsFolder
        self.revealFolder = revealFolder
        builtVersion = Self.bundleVersion(bundle)
        if let pretend = environment["SOLSTREAM_PRETEND_VERSION"].flatMap(ReleaseVersion.init) {
            currentVersion = pretend.text
            isPretending = true
        } else {
            currentVersion = Self.bundleVersion(bundle)
            isPretending = false
        }
    }

    // MARK: - What this copy is

    /// The bundle's own version, or 0.0.0 for a build that has none -- which
    /// any release is newer than, as it should be.
    nonisolated static func bundleVersion(_ bundle: Bundle) -> String {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            .flatMap(ReleaseVersion.init)?.text ?? "0.0.0"
    }

    /// The running bundle, when it is SolStream's own .app: `swift run` and
    /// the test runner are neither, and must never be replaced.
    nonisolated static func installableBundle(_ bundle: Bundle) -> URL? {
        guard bundle.bundleURL.pathExtension == "app",
              bundle.bundleIdentifier == UpdateSource.bundleIdentifier else { return nil }
        return bundle.bundleURL
    }

    nonisolated static var defaultDownloadsFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(UpdateSource.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }

    private var token: String? {
        let value = environment["SOLSTREAM_GITHUB_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private var userAgent: String { "SolStream/\(currentVersion) (macOS)" }

    // MARK: - Schedule

    /// At launch: tidy up after an update that just went in, then check in a
    /// minute and every day after.
    func start() {
        guard timers.isEmpty else { return }
        cleanUpAfterUpdate()
        if isPretending {
            Log.info("[update] pretending to be \(currentVersion) (SOLSTREAM_PRETEND_VERSION)")
        }
        if token != nil {
            // That there is one, never what it is.
            Log.info("[update] using the GitHub token in SOLSTREAM_GITHUB_TOKEN")
        }
        if !checksOnItsOwn {
            Log.info("[update] a build outside SolStream.app: automatic checks off, Check now still works")
        }
        let first = Timer.scheduledTimer(withTimeInterval: Self.launchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.askedThisRun == nil else { return }
                self.automaticCheck()
            }
        }
        // Hourly, asking whether a day has passed, rather than one 24-hour
        // timer: a timer's clock stops while the Mac sleeps, so a laptop that
        // is closed every evening would otherwise put the check off for ever.
        let daily = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDue else { return }
                self.automaticCheck()
            }
        }
        daily.tolerance = 5 * 60
        timers = [first, daily]
    }

    var isDue: Bool {
        guard let lastCheck else { return true }
        let elapsed = Date().timeIntervalSince(lastCheck)
        // A check stamped while the clock ran ahead is in the future once it
        // is put right; waiting for real time to catch up could take weeks.
        return elapsed < 0 || elapsed >= Self.interval
    }

    /// A build run outside a bundle -- `swift run` -- is a developer's, at
    /// 0.0.0, which every release is newer than: checking on its own would
    /// only put "Update available" on the connect window of every run.
    /// SOLSTREAM_PRETEND_VERSION, being a request to test the updater, turns
    /// it back on.
    var checksOnItsOwn: Bool { installTarget != nil || isPretending }

    /// A check nobody asked for: only with the setting on, and not while
    /// something is already found, downloading or going in.
    func automaticCheck() {
        guard checksAutomatically, checksOnItsOwn else { return }
        switch state {
        case .idle, .upToDate, .failed: break
        default: return
        }
        Task { await check() }
    }

    /// "Check for Updates…" and the Check now button.
    func checkNow() {
        Task { await check() }
    }

    // MARK: - Checking

    /// One check, and the download that follows it when there is something
    /// new. At most one at a time: a second call while one is in flight
    /// returns nil and changes nothing.
    @discardableResult
    func check() async -> CheckOutcome? {
        switch state {
        case .checking, .downloading, .installing: return nil
        // A promise about the download in hand, or an install already made:
        // a check now could swap the one for another release, or put the
        // promise back after the stream it was waiting for had closed.
        case .waitingForStream, .installed: return nil
        default: break
        }
        let previous = state
        state = .checking
        askedThisRun = Date()
        do {
            let outcome = try await latest()
            defaults.set(Date(), forKey: Key.lastCheck)
            switch outcome {
            case .nothingVisible:
                Log.info("[update] checked: nothing published that this Mac can see "
                         + "(404), running \(currentVersion)")
                remember("upToDate")
                state = .upToDate
            case .upToDate(let latest):
                Log.info("[update] checked: up to date, running \(currentVersion), latest \(latest)")
                remember("upToDate")
                state = .upToDate
            case .newer(let release):
                let version = release.version.text
                Log.info("[update] checked: \(version) is available, running \(currentVersion)")
                remember("available \(version)")
                offered = release
                if let downloaded, downloaded.version == version,
                   FileManager.default.fileExists(atPath: downloaded.zip.path) {
                    // Already here: not fetched again.
                    state = readyState(version)
                } else {
                    state = .available(version)
                    if !isStreaming, installTarget != nil { await download() }
                }
            }
            return outcome
        } catch {
            let failure = UpdateError(error)
            Log.error("[update] check failed: \(failure.detail)")
            remember("failed")
            // A failed re-check does not lose an update already found, let
            // alone one downloaded: lost, nothing would bring it back before
            // the next daily check, as `lastCheck` still holds the one that
            // found it.
            if case .available = previous {
                state = previous
            } else {
                state = downloaded == nil ? .failed(failure.reason) : previous
            }
            return nil
        }
    }

    /// A build run from outside a bundle -- `swift run`, say -- can fetch an
    /// update but has nothing to put it in place of.
    private static func cannotReplaceItself(_ version: String) -> State {
        .manualInstall(version, reason: "This copy can't replace itself.")
    }

    /// What a verified download offers: the install, or -- for a copy on the
    /// disk image, a translocated one, or one in a folder this user cannot
    /// write -- the download, rather than a button that can only fail. The
    /// install checks again, as the folder can change in between.
    private func readyState(_ version: String) -> State {
        guard let installTarget else { return Self.cannotReplaceItself(version) }
        guard UpdateInstaller.canReplace(installTarget) else {
            let folder = installTarget.deletingLastPathComponent()
            Log.info("[update] \(folder.path) is not writable; offering the download of \(version) instead")
            return .manualInstall(version, reason: UpdateError.install(.notWritable(folder)).reason)
        }
        return .ready(version)
    }

    private func remember(_ result: String) {
        defaults.set(result, forKey: Key.lastResult)
    }

    /// Ask GitHub for the latest release and compare it with this copy.
    func latest() async throws -> CheckOutcome {
        let response = try await transport.fetch(
            request(UpdateSource.latestRelease, accept: "application/vnd.github+json"),
            limit: 1024 * 1024)
        switch response.status {
        case 200: break
        case 404: return .nothingVisible
        case 401: throw UpdateError.tokenRefused
        case 403, 429: throw UpdateError.rateLimited
        default: throw UpdateError.http(response.status)
        }
        guard let release = try Release.parse(response.body) else {
            // A draft or a prerelease: not for this updater, so nothing new.
            return .upToDate(latest: currentVersion)
        }
        guard let current = ReleaseVersion(currentVersion), release.version > current else {
            return .upToDate(latest: release.version.text)
        }
        // SOLSTREAM_PRETEND_VERSION left set must not offer a release this
        // build would then refuse to install: nothing not newer than the real
        // bundle, matching the Windows updater.
        if isPretending, let built = ReleaseVersion(builtVersion), release.version <= built {
            return .upToDate(latest: release.version.text)
        }
        return .newer(release)
    }

    private func request(_ url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.host?.lowercased() == UpdateHosts.tokenHost {
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        }
        return request
    }

    /// With a token, the API's address for the asset, which takes one; without,
    /// the public one, which does not -- and which is all a public repository
    /// needs.
    private func request(for asset: Release.Asset) -> URLRequest {
        request(token == nil ? asset.downloadURL : asset.apiURL, accept: "application/octet-stream")
    }

    // MARK: - Downloading

    /// Fetch and verify the update found by the last check. Not during a
    /// stream: the download waits for it to close.
    func download() async {
        guard let release = offered, !isStreaming else { return }
        switch state {
        case .checking, .downloading, .installing, .installed: return
        default: break
        }
        let version = release.version.text
        state = .downloading(version, nil)
        do {
            let (zip, sha256) = try await fetchVerified(release)
            downloaded = (version, zip, sha256)
            let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            Log.info("[update] \(version) downloaded and verified "
                     + "(\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)))")
            state = readyState(version)
        } catch UpdateTransport.Failure.cancelled {
            Log.info("[update] \(version) download stopped for a stream; it starts again when the stream closes")
            state = .available(version)
            // The stream may have closed again before the cancel landed, and
            // its closing found the download still running.
            if !isStreaming, installTarget != nil { Task { await download() } }
        } catch {
            let failure = UpdateError(error)
            Log.error("[update] \(version) discarded: \(failure.detail)")
            state = .failed(failure.reason)
        }
    }

    /// The sums, their signature, then the archive -- each check passed
    /// before the next byte is fetched, and the archive's hash matched before
    /// it is called a download. Returns where the archive is and its line in
    /// the sums.
    func fetchVerified(_ release: Release) async throws -> (zip: URL, sha256: String) {
        let version = release.version.text
        let zipName = UpdateSource.zipName(for: version)
        guard let zipAsset = release.asset(named: zipName) else { throw UpdateError.missingAsset(zipName) }
        guard let sumsAsset = release.asset(named: UpdateSource.sumsName) else {
            throw UpdateError.missingAsset(UpdateSource.sumsName)
        }
        guard let signatureAsset = release.asset(named: UpdateSource.signatureName) else {
            throw UpdateError.missingAsset(UpdateSource.signatureName)
        }
        guard zipAsset.size <= UpdateSource.maximumAssetBytes else { throw UpdateError.tooLarge }

        let sums = try await fetchSmall(sumsAsset)
        let signature = try await fetchSmall(signatureAsset)
        // Before a line of the sums is read: until the signature holds, they
        // are just bytes from the network.
        guard UpdateSignature.isValid(signature: signature, for: sums, publicKey: publicKey) else {
            throw UpdateError.badSignature
        }
        guard let list = ChecksumList.parse(sums) else { throw UpdateError.malformedSums }
        guard let expected = list[zipName] else { throw UpdateError.notInSums(zipName) }

        // This user's alone, which keeps out other users. Not this user's
        // other programs: the installer hashes the archive again before it
        // unpacks it, which catches one swapped while it waited here.
        let owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: downloadsFolder, withIntermediateDirectories: true,
                                                attributes: owner)
        try FileManager.default.setAttributes(owner, ofItemAtPath: downloadsFolder.path)
        let file = downloadsFolder.appendingPathComponent(zipName)
        // Whole percents only: a byte count per packet would be thousands of
        // trips to the main thread to redraw the same figure.
        var shown = -1
        let advertised = zipAsset.size
        let progress: (Int64, Int64?) -> Void = { [weak self] received, total in
            let size = total ?? (advertised > 0 ? advertised : nil)
            guard let size, size > 0 else { return }
            let percent = Int(min(1, Double(received) / Double(size)) * 100)
            guard percent != shown else { return }
            shown = percent
            Task { @MainActor in
                guard let self, case .downloading(version, _) = self.state else { return }
                self.state = .downloading(version, Double(percent) / 100)
            }
        }
        // Looked at again here, not only when the download began: the sums
        // and the signature take a moment, and a stream may have opened. From
        // the next line on, a stream opening cancels the fetch itself.
        guard !isStreaming else { throw UpdateTransport.Failure.cancelled }
        let transport = self.transport
        let zipRequest = request(for: zipAsset)
        let fetch = Task {
            try await transport.fetch(zipRequest, limit: UpdateSource.maximumAssetBytes,
                                      into: file, progress: progress)
        }
        zipFetch = fetch
        defer { zipFetch = nil }
        let response = try await fetch.value
        guard response.status == 200 else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError.http(response.status)
        }
        guard response.digest == expected else {
            try? FileManager.default.removeItem(at: file)
            throw UpdateError.checksumMismatch
        }
        return (file, expected)
    }

    private func fetchSmall(_ asset: Release.Asset) async throws -> Data {
        let response = try await transport.fetch(request(for: asset),
                                                 limit: UpdateSource.maximumSmallAssetBytes)
        guard response.status == 200 else { throw UpdateError.http(response.status) }
        return response.body
    }

    // MARK: - Installing

    /// The button. During a stream it only promises to install when the
    /// stream closes; otherwise it installs and relaunches now.
    func installAndRelaunch() {
        guard case .ready(let version) = state, let downloaded, downloaded.version == version else {
            return
        }
        guard !isStreaming else {
            Log.info("[update] \(version) will install when the stream closes")
            state = .waitingForStream(version)
            return
        }
        install(version: version, zip: downloaded.zip, sha256: downloaded.sha256)
    }

    /// Take back "install when the stream closes".
    func cancelPendingInstall() {
        guard case .waitingForStream(let version) = state else { return }
        Log.info("[update] \(version) will not install when the stream closes")
        state = .ready(version)
    }

    private func install(version: String, zip: URL, sha256: String) {
        guard let target = installTarget else {
            state = Self.cannotReplaceItself(version)
            return
        }
        state = .installing(version)
        Task {
            // ditto and codesign take a second or two; not on the main thread.
            let result = await Task.detached(priority: .userInitiated) {
                Result { try UpdateInstaller.install(zip: zip, sha256: sha256, version: version,
                                                     replacing: target) }
            }.value
            switch result {
            case .success(let replaced):
                // Deleted by the copy that starts next, once it has started:
                // until then this one is the way back.
                defaults.set(replaced.path, forKey: Key.replacedBundle)
                try? FileManager.default.removeItem(at: zip)
                downloaded = nil
                Log.info("[update] installed \(version) at \(target.path)")
                // "Install when the stream closes" runs as the stream closes,
                // and the picker is back a moment later: a stream can open in
                // the second or two the install takes, and quitting would end
                // it.
                guard !isStreaming else {
                    Log.info("[update] a stream opened during the install; restarting when it closes")
                    state = .installed(version)
                    return
                }
                restart(into: version)
            case .failure(let error):
                let failure = UpdateError(error)
                Log.error("[update] \(version) not installed: \(failure.detail)")
                if case .install(.notWritable) = failure {
                    state = .manualInstall(version, reason: failure.reason)
                } else {
                    // A download that fails its checks is not kept, so it
                    // cannot be offered a second time.
                    try? FileManager.default.removeItem(at: zip)
                    downloaded = nil
                    state = .failed(failure.reason)
                }
            }
        }
    }

    /// Quit, and have the new copy at the same path start once this one has
    /// gone.
    private func restart(into version: String) {
        guard let target = installTarget else { return }
        Log.info("[update] relaunching into \(version)")
        Log.flush()
        do {
            try relaunch(target)
        } catch {
            Log.error("[update] could not relaunch: \(error.localizedDescription)")
            state = .failed("Installed. Quit and open SolStream again to finish.")
            return
        }
        terminate()
    }

    /// For a copy that cannot replace itself: put the download in Downloads,
    /// where somebody installing by hand would look for it, and show it.
    func revealDownload() {
        guard let downloaded, FileManager.default.fileExists(atPath: downloaded.zip.path) else { return }
        var shown = downloaded.zip
        // Moved once; pressed again, it is shown where it already is, not
        // renamed to a "2" beside itself.
        if let folder = revealFolder,
           downloaded.zip.deletingLastPathComponent().resolvingSymlinksInPath().path
            != folder.resolvingSymlinksInPath().path {
            var destination = folder.appendingPathComponent(downloaded.zip.lastPathComponent)
            var copy = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent(
                    "SolStream-\(downloaded.version)-macOS \(copy).zip")
                copy += 1
            }
            if (try? FileManager.default.moveItem(at: downloaded.zip, to: destination)) != nil {
                shown = destination
                self.downloaded = (downloaded.version, destination, downloaded.sha256)
            }
        }
        Log.info("[update] showing the download of \(downloaded.version) at \(shown.path)")
        showInFinder([shown])
    }

    /// The copy an update set aside, deleted now that its replacement is the
    /// one running; and any download a previous run left behind.
    ///
    /// Only a path this updater recorded, with the name it gives, in the same
    /// folder as the running bundle: a value in the defaults is not reason
    /// enough to delete anything else.
    func cleanUpAfterUpdate() {
        if let path = defaults.string(forKey: Key.replacedBundle) {
            defaults.removeObject(forKey: Key.replacedBundle)
            let old = URL(fileURLWithPath: path)
            if old.lastPathComponent.hasPrefix(UpdateInstaller.replacedPrefix),
               old.pathExtension == "app", let installTarget,
               old.deletingLastPathComponent().standardizedFileURL
                == installTarget.deletingLastPathComponent().standardizedFileURL {
                do {
                    try FileManager.default.removeItem(at: old)
                    Log.info("[update] now running \(currentVersion); removed the copy it replaced")
                } catch {
                    // Not yet seen on a real install: macOS's App Management
                    // may refuse one app changing another's contents, and a
                    // release is ad-hoc signed, with no team to share. The
                    // Trash takes the bundle whole -- a move, not a change
                    // inside it -- so nothing hidden is left in Applications.
                    do {
                        try FileManager.default.trashItem(at: old, resultingItemURL: nil)
                        Log.info("[update] now running \(currentVersion); could not delete the copy it "
                                 + "replaced (\(error.localizedDescription)), so moved it to the Trash")
                    } catch let trashError {
                        Log.error("[update] could not remove \(old.path): \(error.localizedDescription); "
                                  + "nor move it to the Trash: \(trashError.localizedDescription)")
                    }
                }
            }
        }
        if FileManager.default.fileExists(atPath: downloadsFolder.path) {
            try? FileManager.default.removeItem(at: downloadsFolder)
        }
    }

    // MARK: - Words

    /// One line for Settings and the log of what is going on.
    var statusText: String {
        switch state {
        case .idle:
            guard let lastCheck else { return "Not checked yet." }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let when = formatter.localizedString(for: lastCheck, relativeTo: Date())
            return lastResult == "upToDate" ? "Up to date. Checked \(when)." : "Last checked \(when)."
        case .checking:
            return "Checking…"
        case .upToDate:
            return "Up to date."
        case .available(let version):
            // Only a copy that can install downloads by itself once the
            // stream closes; any other waits for Download.
            return isStreaming && installTarget != nil ? "Update \(version) downloads after the stream."
                                                       : "Update \(version) is available."
        case .downloading(let version, let fraction):
            return fraction.map { "Downloading \(version)… \(Int(($0 * 100).rounded()))%" }
                ?? "Downloading \(version)…"
        case .ready(let version):
            return "Update \(version) is ready to install."
        case .waitingForStream(let version):
            return "Update \(version) installs when the stream closes."
        case .installing(let version):
            return "Installing \(version)…"
        case .installed(let version):
            // Two lines beside the button at most, even for 10.10.10.
            return "Update \(version) is installed. Restarts after the stream."
        case .manualInstall(_, let reason), .failed(let reason):
            return reason
        }
    }

    /// The version to mention outside Settings, when there is one to mention.
    var announcedVersion: String? {
        switch state {
        case .available(let version), .downloading(let version, _), .ready(let version),
             .waitingForStream(let version), .manualInstall(let version, _):
            return version
        default:
            return nil
        }
    }

    private func announce() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// Everything that can stop an update, in the words Settings shows -- short,
/// because they sit beside a button -- and the detail the log gets.
enum UpdateError: Error, Equatable {
    case transport(UpdateTransport.Failure)
    case http(Int)
    case tokenRefused
    case rateLimited
    case malformedRelease
    case missingAsset(String)
    case tooLarge
    case badSignature
    case malformedSums
    case notInSums(String)
    case checksumMismatch
    case install(UpdateInstaller.Failure)

    init(_ error: Error) {
        switch error {
        case let failure as UpdateError: self = failure
        case UpdateTransport.Failure.tooLarge: self = .tooLarge
        case let failure as UpdateTransport.Failure: self = .transport(failure)
        case let failure as UpdateInstaller.Failure: self = .install(failure)
        case is Release.ParseError: self = .malformedRelease
        // FileManager's: the download folder could not be made or written.
        case is CocoaError: self = .transport(.cannotWrite)
        default: self = .transport(.network(error.localizedDescription))
        }
    }

    var reason: String {
        switch self {
        case .transport(.offline), .transport(.network): return "Couldn't reach GitHub."
        case .transport(.timedOut): return "GitHub didn't answer in time."
        case .transport(.refusedAddress): return "The download left GitHub, so it was stopped."
        case .transport(.cannotWrite): return "Couldn't save the download."
        case .transport(.cancelled): return "The download was stopped."
        case .transport(.tooLarge), .tooLarge: return "The download was too large to be an update."
        case .http(let status): return "GitHub answered with error \(status)."
        case .tokenRefused: return "GitHub didn't accept the token."
        case .rateLimited: return "GitHub is limiting requests for now."
        case .malformedRelease: return "GitHub's answer couldn't be read."
        case .missingAsset: return "The release is missing a file."
        case .badSignature: return "The update's signature didn't verify."
        case .malformedSums, .notInSums: return "The update's checksums didn't verify."
        case .checksumMismatch, .install(.checksumMismatch): return "The download didn't match its checksum."
        case .install(.notNewer): return "This copy is already up to date."
        case .install(.notWritable): return "SolStream can't replace itself here."
        case .install(.wrongIdentifier): return "The download isn't SolStream."
        case .install(.wrongVersion): return "The download is the wrong version."
        case .install(.signatureRejected): return "The new copy's signature didn't verify."
        case .install(.notAnApp), .install(.unpackFailed): return "The download couldn't be unpacked."
        case .install(.moveFailed): return "The new copy couldn't be moved into place."
        }
    }

    /// For the log. Never contains the token: nothing here was built from it.
    var detail: String {
        switch self {
        case .transport(.offline): return "GitHub could not be reached (offline?)"
        case .transport(.timedOut): return "GitHub timed out"
        case .transport(.refusedAddress(let host)): return "refused to fetch from \(host)"
        case .transport(.cannotWrite): return "could not write the download"
        case .transport(.cancelled): return "cancelled"
        case .transport(.network(let message)): return "network error: \(message)"
        case .transport(.tooLarge), .tooLarge:
            return "larger than \(UpdateSource.maximumAssetBytes / 1024 / 1024) MB"
        case .http(let status): return "HTTP \(status)"
        case .tokenRefused: return "HTTP 401: SOLSTREAM_GITHUB_TOKEN was not accepted"
        case .rateLimited: return "HTTP 403/429: rate limited"
        case .malformedRelease: return "the release JSON could not be parsed"
        case .missingAsset(let name): return "the release has no \(name)"
        case .badSignature: return "SHA256SUMS.sig does not verify against the compiled-in key"
        case .malformedSums: return "SHA256SUMS is malformed"
        case .notInSums(let name): return "SHA256SUMS does not list \(name)"
        case .checksumMismatch: return "SHA-256 does not match SHA256SUMS"
        case .install(.checksumMismatch): return "the archive changed after it was downloaded and verified"
        case .install(.notNewer(let found)): return "the bundle being replaced is already \(found)"
        case .install(.notWritable(let folder)): return "\(folder.path) is not writable"
        case .install(.wrongIdentifier(let found)): return "bundle id is \(found ?? "missing")"
        case .install(.wrongVersion(let found)): return "bundle version is \(found ?? "missing")"
        case .install(.signatureRejected(let output)): return "codesign: \(output)"
        case .install(.notAnApp): return "the archive does not hold exactly one .app"
        case .install(.unpackFailed(let output)): return "ditto: \(output)"
        case .install(.moveFailed(let message)): return "rename failed: \(message)"
        }
    }
}
