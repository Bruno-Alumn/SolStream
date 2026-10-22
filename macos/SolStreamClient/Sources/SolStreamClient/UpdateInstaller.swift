import CryptoKit
import Foundation

/// Puts a verified download in place of an app bundle.
///
/// Every step takes the bundle to replace as an argument rather than reading
/// `Bundle.main`, so the tests run it against a fake bundle in a temporary
/// folder and the real application is never in reach.
///
/// The download's checksum was matched against signed sums when it arrived,
/// but it may have waited hours in a folder anything running as this user can
/// write to. So the archive is copied into a folder of this user's own and
/// hashed again, and only that copy is unpacked: that hash is the one link
/// between what goes in and what the release signed.
///
/// What is checked after unpacking -- SolStream's identifier, exactly the
/// version the release said and newer than the copy it replaces, a code
/// signature that still verifies -- catches a broken or mislabelled build, not
/// a forged one. An ad-hoc signature names nobody, so a program running as this
/// user that swapped the unpacked bundle before the rename would pass them all;
/// such a program could as well change the installed copy directly. A
/// Developer ID would close that; see `unpack`.
///
/// The swap itself is two renames in one folder, so there is no moment at
/// which a half-copied application sits where the old one was.
enum UpdateInstaller {
    enum Failure: Error, Equatable {
        /// The archive is not the one whose hash the signed sums gave.
        case checksumMismatch
        /// The bundle being replaced is already this version or newer.
        case notNewer(String)
        case unpackFailed(String)
        /// The archive did not hold exactly one application.
        case notAnApp
        case wrongIdentifier(String?)
        case wrongVersion(String?)
        case signatureRejected(String)
        /// The folder the application is in cannot be written by this user,
        /// or macOS would not let the application be moved.
        case notWritable(URL)
        case moveFailed(String)
    }

    /// Where the running copy was moved to, named so the next launch can tell
    /// it is one of ours and nothing else.
    static let replacedPrefix = ".SolStream-replaced-"

    /// Whether `target` can be swapped out with renames, without asking for an
    /// administrator's password -- which this never does.
    ///
    /// A copy run straight from the disk image, or one macOS has translocated
    /// because it was never moved out of Downloads, sits on a read-only path,
    /// and says so here rather than failing halfway.
    static func canReplace(_ target: URL) -> Bool {
        let folder = target.deletingLastPathComponent()
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        return manager.fileExists(atPath: target.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && !target.path.contains("/AppTranslocation/")
            && manager.isWritableFile(atPath: folder.path)
    }

    /// Copy, hash, unpack, check, and swap. `sha256` is the archive's line in
    /// the signed sums. Returns where the old bundle now is, which the caller
    /// deletes once the new one has started.
    static func install(zip: URL, sha256: String, version: String, replacing target: URL,
                        bundleIdentifier: String = UpdateSource.bundleIdentifier) throws -> URL {
        guard canReplace(target) else { throw Failure.notWritable(target.deletingLastPathComponent()) }
        // Never sideways and never down, whatever SOLSTREAM_PRETEND_VERSION
        // told the check: measured against the bundle actually being replaced.
        // A bundle with no version is 0.0.0, as `Updater.bundleVersion` says.
        let installed = bundleVersion(target)
        guard let new = ReleaseVersion(version),
              installed.flatMap(ReleaseVersion.init).map({ new > $0 }) ?? true else {
            throw Failure.notNewer(installed ?? "unknown")
        }
        // A temporary folder on the target's own volume, so the final move is
        // a rename and never a copy across disks; this user's alone.
        let work: URL
        do {
            work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: target, create: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        } catch {
            throw Failure.moveFailed(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("update.zip")
        guard try copyAndHash(zip, to: archive) == sha256 else { throw Failure.checksumMismatch }
        let app = try unpack(zip: archive, into: work, version: version, bundleIdentifier: bundleIdentifier)
        return try replace(target, with: app)
    }

    /// The version in a bundle's Info.plist, read from the file itself.
    static func bundleVersion(_ app: URL) -> String? {
        // Straight from the file: `Bundle(url:)` caches by path, and the same
        // path holds a different bundle after a swap.
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        return plist?["CFBundleShortVersionString"] as? String
    }

    /// Copy `source` to `destination` a megabyte at a time, hashing what is
    /// written, so the hash is of the bytes `ditto` will read and not of a
    /// file that could be changed between the two.
    private static func copyAndHash(_ source: URL, to destination: URL) throws -> String {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: source)
        } catch {
            throw Failure.unpackFailed(error.localizedDescription)
        }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: destination) else {
            throw Failure.unpackFailed("could not copy the archive")
        }
        defer { try? output.close() }
        var hasher = SHA256()
        var copied: Int64 = 0
        do {
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                copied += Int64(chunk.count)
                // The same cap as the download: a file that grew is not it.
                guard copied <= UpdateSource.maximumAssetBytes else { throw Failure.checksumMismatch }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.unpackFailed(error.localizedDescription)
        }
        return ChecksumList.hex(hasher.finalize())
    }

    /// `ditto -x -k` the archive into a fresh folder inside `work`, then check
    /// what came out. Returns the application, still inside `work`.
    static func unpack(zip: URL, into work: URL, version: String,
                       bundleIdentifier: String = UpdateSource.bundleIdentifier) throws -> URL {
        let folder = work.appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw Failure.unpackFailed(error.localizedDescription)
        }
        let unzip = run("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
        guard unzip.status == 0 else { throw Failure.unpackFailed(unzip.output) }

        // `ditto --keepParent` puts the bundle at the top. Exactly one, and a
        // real folder rather than a link to somewhere else; anything beside it
        // that is not an application, a stray `__MACOSX` say, is ignored.
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let apps = entries.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first,
              let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true, values.isDirectory == true else {
            throw Failure.notAnApp
        }

        // Read straight from the file: `Bundle(url:)` caches by path, and the
        // same temporary path can come round again.
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        let plist = (try? Data(contentsOf: plistURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let identifier = plist?["CFBundleIdentifier"] as? String
        guard identifier == bundleIdentifier else { throw Failure.wrongIdentifier(identifier) }
        let found = bundleVersion(app)
        guard found == version else { throw Failure.wrongVersion(found) }

        // Whole and unaltered since it was sealed -- which, for an ad-hoc
        // seal, says nothing about who sealed it.
        // TODO: once releases are signed with a Developer ID, add
        // `-R=anchor apple generic and certificate leaf[subject.OU] = "TEAMID"`
        // here, which binds the bundle to its signer.
        let check = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard check.status == 0 else { throw Failure.signatureRejected(check.output) }
        return app
    }

    /// Move `target` aside under a hidden name in its own folder, then move
    /// `newApp` to where it was. If the second move fails the first is undone,
    /// so a failure leaves the application exactly as it was found.
    static func replace(_ target: URL, with newApp: URL) throws -> URL {
        let folder = target.deletingLastPathComponent()
        let aside = folder.appendingPathComponent("\(replacedPrefix)\(UUID().uuidString).app",
                                                  isDirectory: true)
        try rename(target, to: aside)
        do {
            try rename(newApp, to: target)
        } catch {
            do {
                try rename(aside, to: target)
            } catch let undo {
                // The one failure that leaves no application where it was --
                // App Management letting the first rename through and not the
                // next, say. Its hidden name is said, so the log line is
                // enough to put it back by hand.
                throw Failure.moveFailed("\(error); the old copy could not be put back "
                                         + "and is at \(aside.path): \(undo)")
            }
            throw error
        }
        return aside
    }

    /// rename(2) itself, not FileManager's move: that falls back to copying
    /// when the two paths are on different volumes, and a copy is exactly the
    /// half-finished state the swap exists to avoid.
    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) != 0 else { return }
        let code = errno
        switch code {
        case EACCES, EPERM, EROFS:
            throw Failure.notWritable(destination.deletingLastPathComponent())
        default:
            throw Failure.moveFailed(String(cString: strerror(code)))
        }
    }

    /// What the tools started here see of the environment: a fixed PATH and the
    /// few names that say who and where the user is. Inherited whole, it would
    /// hand SOLSTREAM_GITHUB_TOKEN to ditto, codesign and the relaunch shell,
    /// where any program of this user's could read it -- and none of them
    /// needs it. `open` hands its own environment to the app it starts
    /// (man open), so the relaunched copy starts with this one too: no token
    /// and no pretend version. A token given for one launch ends with the update.
    static func toolEnvironment(from inherited: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["HOME", "TMPDIR", "USER", "LOGNAME"] {
            environment[key] = inherited[key]
        }
        return environment
    }

    /// A tool's exit status and what it printed, for the log.
    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = toolEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Read before waiting: a tool that fills the pipe would otherwise
        // wait for us while we wait for it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    /// Start `app` once this process has gone, from a shell that outlives it.
    ///
    /// `open` while the old copy is still running would only bring the old
    /// copy forward, so the shell waits for this process ID to disappear --
    /// ten seconds at most -- and then opens the new bundle. The path and the
    /// ID go in as arguments, never spliced into the script.
    static func relaunch(_ app: URL) throws {
        let script = """
            i=0
            while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
            exec /usr/bin/open -n "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "solstream-relaunch", "\(getpid())", app.path]
        process.environment = toolEnvironment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
