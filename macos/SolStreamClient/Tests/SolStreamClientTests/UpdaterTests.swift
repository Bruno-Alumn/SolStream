import CryptoKit
import Foundation
import XCTest
@testable import SolStreamClient

/// The updater against docs/updates.md: the signature vector, the formats, a
/// check and a download over a stubbed network, and an install into a fake
/// bundle in a temporary folder.
///
/// Nothing here reaches GitHub, the real application or the real caches: the
/// network is a URLProtocol stub, every updater gets its own defaults suite,
/// download folder and install target, and the release a test publishes is
/// signed with a key the test makes and throws away.
final class UpdaterTests: XCTestCase {
    private var scratch: URL!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-updater-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // A path, not a name: a named suite leaves its plist behind in
        // ~/Library/Preferences after every run, even once emptied. This one
        // lives in the scratch folder and goes with it.
        suiteName = scratch.appendingPathComponent("defaults").path
        StubProtocol.reset()
    }

    override func tearDownWithError() throws {
        // Put back anything a test made read-only, or it cannot be removed.
        if let enumerator = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
        StubProtocol.reset()
        try super.tearDownWithError()
    }

    // MARK: - The signature

    private static var vector: URL {
        // Tests/SolStreamClientTests/UpdaterTests.swift -> the repository root.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("tests/update-vector", isDirectory: true)
    }

    private func vectorFile(_ name: String) throws -> Data {
        try Data(contentsOf: Self.vector.appendingPathComponent(name))
    }

    private var testKey: String {
        get throws {
            try XCTUnwrap(String(data: vectorFile("test-key.pub.b64"), encoding: .ascii))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func testTheVectorVerifiesWithTheTestKey() throws {
        XCTAssertTrue(UpdateSignature.isValid(signature: try vectorFile("SHA256SUMS.sig"),
                                              for: try vectorFile("SHA256SUMS"),
                                              publicKey: try testKey))
    }

    /// The vector as docs/updates.md prints it is the same as the files.
    func testTheDocumentedVectorIsTheOneInTheFiles() throws {
        XCTAssertEqual(try testKey,
                       "BHEGr5w8p3a2JdZmAKyJVj4ZPCeHcfB3PW3b2LhNliZ8x/KWp+N8YY6ywrVXg2k2PF4KWIaDmqwC1WdRCryoA8c=")
        XCTAssertEqual(try vectorFile("SHA256SUMS").base64EncodedString(),
                       "M2YxYzRjYWI1YjJmMmQ4ZjlhM2Y2MWUwZDRjM2IyYTE5MDhmN2U2ZDVjNGIzYTI5MTgwN2Y2ZTVkNGMzYjJhMSAgU29sU3RyZWFtLTkuOS45LW1hY09TLnppcAphMGIxYzJkM2U0ZjUwNjE3MjgzOTRhNWI2YzdkOGU5ZmEwYjFjMmQzZTRmNTA2MTcyODM5NGE1YjZjN2Q4ZTlmICBTb2xTdHJlYW1TZXR1cC05LjkuOS5leGUK")
    }

    func testAnyChangedByteOfTheSumsFailsTheSignature() throws {
        let sums = try vectorFile("SHA256SUMS")
        let signature = try vectorFile("SHA256SUMS.sig")
        let key = try testKey
        for index in sums.indices {
            var tampered = sums
            tampered[index] ^= 0x01
            XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: tampered, publicKey: key),
                           "byte \(index) changed and the signature still held")
        }
        XCTAssertFalse(UpdateSignature.isValid(signature: signature, for: sums + Data("x".utf8),
                                               publicKey: key))
    }

    func testTheProductionKeyRejectsTheTestSignature() throws {
        XCTAssertFalse(UpdateSignature.isValid(signature: try vectorFile("SHA256SUMS.sig"),
                                               for: try vectorFile("SHA256SUMS")))
        XCTAssertFalse(UpdateSignature.isValid(signature: try vectorFile("SHA256SUMS.sig"),
                                               for: try vectorFile("SHA256SUMS"),
                                               publicKey: UpdateSignature.productionKey))
    }

    /// The key in the code is the one docs/updates.md publishes, and the
    /// release workflow reads from there: a rotation has to change both.
    func testTheCompiledInKeyIsTheOneTheContractPublishes() throws {
        let contract = Self.vector.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/updates.md")
        let lines = try String(contentsOf: contract, encoding: .utf8).components(separatedBy: "\n")
        let marker = try XCTUnwrap(lines.firstIndex { $0.contains("compiled into both programs:") })
        let published = try XCTUnwrap(lines[(marker + 1)...]
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty })
        XCTAssertEqual(published, UpdateSignature.productionKey)
        XCTAssertNotEqual(published, try testKey)
    }

    func testAMalformedSignatureOrKeyIsRejectedNotTrusted() throws {
        let sums = try vectorFile("SHA256SUMS")
        let key = try testKey
        let raw = try XCTUnwrap(Data(base64Encoded: String(decoding: try vectorFile("SHA256SUMS.sig"),
                                                           as: UTF8.self)
                                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(raw.count, 64)
        // Without its newline it still verifies; a DER signature, a short
        // one, garbage and an empty file do not.
        XCTAssertTrue(UpdateSignature.isValid(signature: Data(raw.base64EncodedString().utf8),
                                              for: sums, publicKey: key))
        XCTAssertFalse(UpdateSignature.isValid(signature: Data(raw.dropLast().base64EncodedString().utf8),
                                               for: sums, publicKey: key))
        let der = try P256.Signing.ECDSASignature(rawRepresentation: raw).derRepresentation
        XCTAssertFalse(UpdateSignature.isValid(signature: Data(der.base64EncodedString().utf8),
                                               for: sums, publicKey: key))
        XCTAssertFalse(UpdateSignature.isValid(signature: Data("not base64 at all\n".utf8),
                                               for: sums, publicKey: key))
        XCTAssertFalse(UpdateSignature.isValid(signature: Data(), for: sums, publicKey: key))
        XCTAssertFalse(UpdateSignature.isValid(signature: try vectorFile("SHA256SUMS.sig"),
                                               for: sums, publicKey: "AAAA"))
        // The production key itself is a real P-256 point.
        let point = try XCTUnwrap(Data(base64Encoded: UpdateSignature.productionKey))
        XCTAssertNoThrow(try P256.Signing.PublicKey(x963Representation: point))
    }

    // MARK: - SHA256SUMS

    func testTheSumsParseExactlyAndFindTheRightAsset() throws {
        let sums = try XCTUnwrap(ChecksumList.parse(try vectorFile("SHA256SUMS")))
        XCTAssertEqual(sums.count, 2)
        XCTAssertEqual(sums["SolStream-9.9.9-macOS.zip"],
                       "3f1c4cab5b2f2d8f9a3f61e0d4c3b2a1908f7e6d5c4b3a291807f6e5d4c3b2a1")
        XCTAssertEqual(sums["SolStreamSetup-9.9.9.exe"],
                       "a0b1c2d3e4f5061728394a5b6c7d8e9fa0b1c2d3e4f5061728394a5b6c7d8e9f")
        XCTAssertNil(sums["SolStream-9.9.8-macOS.zip"])
        XCTAssertEqual(UpdateSource.zipName(for: "9.9.9"), "SolStream-9.9.9-macOS.zip")
    }

    func testMalformedSumsAreRejectedWhole() {
        let hex = String(repeating: "ab", count: 32)
        let good = "\(hex)  SolStream-1.0.0-macOS.zip\n"
        XCTAssertNotNil(ChecksumList.parse(Data(good.utf8)))
        let bad: [String: String] = [
            "no final newline": String(good.dropLast()),
            "CRLF": good.replacingOccurrences(of: "\n", with: "\r\n"),
            "capital hex": good.uppercased(),
            "one space": "\(hex) SolStream-1.0.0-macOS.zip\n",
            "three spaces": "\(hex)   SolStream-1.0.0-macOS.zip\n",
            "binary-mode asterisk": "\(hex) *SolStream-1.0.0-macOS.zip\n",
            "short digest": "\(hex.dropLast())  SolStream-1.0.0-macOS.zip\n",
            "long digest": "\(hex)a  SolStream-1.0.0-macOS.zip\n",
            "not hex": "\(String(repeating: "zz", count: 32))  SolStream-1.0.0-macOS.zip\n",
            "no name": "\(hex)  \n",
            "a path": "\(hex)  ../SolStream-1.0.0-macOS.zip\n",
            "a blank line": good + "\n",
            "a name twice": good + good,
            "empty": "",
            "only a newline": "\n",
            "a tab": "\(hex)  Sol\tStream.zip\n",
        ]
        for (what, text) in bad {
            XCTAssertNil(ChecksumList.parse(Data(text.utf8)), what)
        }
        // One bad line spoils the file: no partial answers.
        XCTAssertNil(ChecksumList.parse(Data((good + "garbage\n").utf8)))
    }

    // MARK: - Versions

    func testVersionsCompareNumericallyPartByPart() throws {
        func v(_ text: String) throws -> ReleaseVersion { try XCTUnwrap(ReleaseVersion(text), text) }
        XCTAssertGreaterThan(try v("1.0.10"), try v("1.0.9"))
        XCTAssertGreaterThan(try v("1.10.0"), try v("1.9.9"))
        XCTAssertGreaterThan(try v("2.0.0"), try v("1.99.99"))
        XCTAssertGreaterThan(try v("1.0.1"), try v("1.0.0"))
        XCTAssertEqual(try v("v1.2.3"), try v("1.2.3"))
        XCTAssertFalse(try v("1.0.0") > v("1.0.0"), "the same version is not newer")
        XCTAssertLessThan(try v("0.0.0"), try v("1.0.0"))
        XCTAssertEqual(try v("v1.0.0").text, "1.0.0", "the v is stripped for the asset names")
        XCTAssertEqual(try v(" 1.0.0\n").text, "1.0.0", "a pretend version typed with a space")
        // Exactly X.Y.Z with no leading zeros and a lowercase v, as VERSION, the
        // release workflow and the Windows updater read it.
        for unreadable in ["", "v", "1..0", "1.0.0-beta", "1.0.0.0.0", "a.b.c", "1.0.", ".1",
                           "1. 0.0", "1.-1.0", "１.0.0", "1234567890.0.0", "vv1.0.0",
                           "1.0", "v1.1", "1.0.0.0", "01.0.0", "1.00.0", "V1.0.0"] {
            XCTAssertNil(ReleaseVersion(unreadable), unreadable)
        }
    }

    // MARK: - The release

    func testTheReleaseIsReadAndItsAssetsFound() throws {
        let release = try XCTUnwrap(Release.parse(Self.releaseJSON(tag: "v1.2.0")))
        XCTAssertEqual(release.tag, "v1.2.0")
        XCTAssertEqual(release.version.text, "1.2.0")
        let zip = try XCTUnwrap(release.asset(named: "SolStream-1.2.0-macOS.zip"))
        XCTAssertEqual(zip.downloadURL.absoluteString,
                       "https://github.com/Bruno-Alumn/SolStream/releases/download/v1.2.0/SolStream-1.2.0-macOS.zip")
        XCTAssertEqual(zip.size, 1234)
        XCTAssertNotNil(release.asset(named: "SHA256SUMS"))
        XCTAssertNotNil(release.asset(named: "SHA256SUMS.sig"))
        XCTAssertNil(release.asset(named: "SolStream-1.1.0-macOS.zip"))
    }

    func testDraftsAndPrereleasesAreIgnored() throws {
        XCTAssertNil(try Release.parse(Self.releaseJSON(tag: "v9.0.0", draft: true)))
        XCTAssertNil(try Release.parse(Self.releaseJSON(tag: "v9.0.0", prerelease: true)))
    }

    func testAReleaseWithoutAssetsHasNone() throws {
        let json = Data(#"{"tag_name": "v1.2.0", "draft": false, "prerelease": false}"#.utf8)
        XCTAssertEqual(try XCTUnwrap(Release.parse(json)).assets, [])
        let empty = try XCTUnwrap(Release.parse(Self.releaseJSON(tag: "v1.2.0", assets: [])))
        XCTAssertNil(empty.asset(named: "SolStream-1.2.0-macOS.zip"))
    }

    /// One asset GitHub describes oddly is dropped, not the whole release:
    /// the updater misses it only if it is one it needs.
    func testAnAssetMissingAFieldIsDroppedNotTheRelease() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.releaseJSON(tag: "v1.2.0"))
            as? [String: Any])
        var assets = try XCTUnwrap(object["assets"] as? [[String: Any]])
        // The .dmg without its address, the .exe with no name at all.
        assets[3]["browser_download_url"] = nil
        assets[4]["name"] = NSNull()
        object["assets"] = assets
        let release = try XCTUnwrap(Release.parse(JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(release.assets.map(\.name), ["SolStream-1.2.0-macOS.zip", "SHA256SUMS", "SHA256SUMS.sig"])
    }

    func testAnUnreadableReleaseIsAnError() {
        XCTAssertThrowsError(try Release.parse(Data("<html>".utf8)))
        XCTAssertThrowsError(try Release.parse(Data(#"{"name": "no tag"}"#.utf8)))
        XCTAssertThrowsError(try Release.parse(Self.releaseJSON(tag: "nightly")))
    }

    // MARK: - Hosts and redirects

    func testOnlyGitHubsHostsOverHTTPSAreAllowed() {
        for allowed in ["https://api.github.com/repos/x", "https://github.com/x",
                        "https://objects.githubusercontent.com/x",
                        "https://release-assets.githubusercontent.com/x",
                        "https://API.GitHub.com/x", "https://github.com:443/x"] {
            XCTAssertTrue(UpdateHosts.isAllowed(URL(string: allowed)), allowed)
        }
        for refused in ["http://api.github.com/x", "https://evil.example/x",
                        "https://github.com.evil.example/x", "https://raw.githubusercontent.com/x",
                        "https://github.com:8443/x", "https://user:pass@github.com/x",
                        "ftp://github.com/x", "file:///etc/passwd"] {
            XCTAssertFalse(UpdateHosts.isAllowed(URL(string: refused)), refused)
        }
        XCTAssertFalse(UpdateHosts.isAllowed(nil))
    }

    /// Followed only onto the allow-list, with the headers the updater chose
    /// carried along.
    func testRedirectsKeepTheirHeaders() throws {
        var original = URLRequest(url: URL(string: "https://github.com/x/releases/download/v1/a.zip")!)
        original.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        let storage = try XCTUnwrap(UpdateHosts.redirect(
            URLRequest(url: URL(string: "https://objects.githubusercontent.com/blob?sig=1")!),
            from: original))
        XCTAssertEqual(storage.value(forHTTPHeaderField: "Accept"), "application/octet-stream")

        var proposed = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/b")!)
        proposed.setValue("text/plain", forHTTPHeaderField: "Accept")
        XCTAssertEqual(try XCTUnwrap(UpdateHosts.redirect(proposed, from: original))
            .value(forHTTPHeaderField: "Accept"), "text/plain", "a header the redirect set is kept")

        XCTAssertNil(UpdateHosts.redirect(URLRequest(url: URL(string: "https://evil.example/x")!),
                                          from: original))
        XCTAssertNil(UpdateHosts.redirect(URLRequest(url: URL(string: "http://github.com/x")!),
                                          from: original))
    }

    func testTheTransportRefusesARedirectOffTheList() async throws {
        let transport = UpdateTransport(configuration: Self.stubbed())
        defer { transport.invalidate() }
        StubProtocol.redirect("https://github.com/a", to: "https://evil.example/a")
        StubProtocol.serve("https://evil.example/a", body: Data("payload".utf8))
        do {
            _ = try await transport.fetch(URLRequest(url: URL(string: "https://github.com/a")!), limit: 1024)
            XCTFail("followed a redirect off the allow-list")
        } catch let failure as UpdateTransport.Failure {
            XCTAssertEqual(failure, .refusedAddress("evil.example"))
        }
        XCTAssertFalse(StubProtocol.requested("https://evil.example/a"))
    }

    func testTheTransportFollowsARedirectOnTheList() async throws {
        let transport = UpdateTransport(configuration: Self.stubbed())
        defer { transport.invalidate() }
        StubProtocol.redirect("https://github.com/b", to: "https://release-assets.githubusercontent.com/b")
        StubProtocol.serve("https://release-assets.githubusercontent.com/b", body: Data("payload".utf8))
        let response = try await transport.fetch(URLRequest(url: URL(string: "https://github.com/b")!),
                                                 limit: 1024)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, Data("payload".utf8))
    }

    func testTheTransportRefusesAnythingButHTTPSToGitHub() async {
        let transport = UpdateTransport(configuration: Self.stubbed())
        defer { transport.invalidate() }
        for address in ["http://github.com/x", "https://evil.example/x"] {
            do {
                _ = try await transport.fetch(URLRequest(url: URL(string: address)!), limit: 1024)
                XCTFail("fetched \(address)")
            } catch {
                XCTAssertTrue(error is UpdateTransport.Failure)
            }
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty, "a refused address still went out")
    }

    func testTheTransportStopsAtItsCap() async throws {
        let transport = UpdateTransport(configuration: Self.stubbed())
        defer { transport.invalidate() }
        // Larger than it says...
        StubProtocol.serve("https://github.com/big", body: Data(count: 4096), headers: ["Content-Length": "4096"])
        do {
            _ = try await transport.fetch(URLRequest(url: URL(string: "https://github.com/big")!), limit: 1024)
            XCTFail("read past the cap")
        } catch let failure as UpdateTransport.Failure {
            XCTAssertEqual(failure, .tooLarge)
        }
        // ...and saying it is larger than an update can be, refused unread.
        let file = scratch.appendingPathComponent("huge.zip")
        StubProtocol.serve("https://github.com/huge", body: Data(count: 16),
                           headers: ["Content-Length": "\(UpdateSource.maximumAssetBytes + 1)"])
        do {
            _ = try await transport.fetch(URLRequest(url: URL(string: "https://github.com/huge")!),
                                          limit: UpdateSource.maximumAssetBytes, into: file)
            XCTFail("accepted a download over 200 MB")
        } catch let failure as UpdateTransport.Failure {
            XCTAssertEqual(failure, .tooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testTheSessionKeepsNothingBetweenChecks() {
        let configuration = UpdateTransport.defaultConfiguration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertGreaterThan(configuration.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(configuration.timeoutIntervalForRequest, 60)
    }

    // MARK: - Checking

    @MainActor
    func testA404MeansNothingVisibleAndIsNotAFailure() async throws {
        let updater = makeUpdater(version: "1.0.0")
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 404,
                           body: Data(#"{"message": "Not Found"}"#.utf8))
        let outcome = await updater.check()
        XCTAssertEqual(outcome, .nothingVisible)
        XCTAssertEqual(updater.state, .upToDate)
        XCTAssertEqual(updater.statusText, "Up to date.")
        XCTAssertNil(updater.announcedVersion)
        XCTAssertNotNil(updater.lastCheck)
        XCTAssertEqual(updater.lastResult, "upToDate")

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url, URL(string: "https://api.github.com/repos/Bruno-Alumn/SolStream/releases/latest"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SolStream/1.0.0 (macOS)")
    }

    @MainActor
    func testOnlyAStrictlyNewerReleaseIsOffered() async throws {
        let updater = makeUpdater(version: "1.0.10")
        for (tag, expected) in [("v1.0.9", Updater.CheckOutcome.upToDate(latest: "1.0.9")),
                                ("v1.0.10", .upToDate(latest: "1.0.10")),
                                ("v1.0.0", .upToDate(latest: "1.0.0"))] {
            StubProtocol.serve(UpdateSource.latestRelease.absoluteString, body: Self.releaseJSON(tag: tag))
            let outcome = await updater.check()
            XCTAssertEqual(outcome, expected, tag)
            XCTAssertEqual(updater.state, .upToDate, tag)
        }
        // A draft or a prerelease, newer or not, is nothing new.
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString,
                           body: Self.releaseJSON(tag: "v2.0.0", prerelease: true))
        let prerelease = await updater.check()
        XCTAssertEqual(prerelease, .upToDate(latest: "1.0.10"))
        XCTAssertEqual(updater.state, .upToDate)
    }

    @MainActor
    func testOnlyOneCheckIsEverInFlight() async throws {
        let updater = makeUpdater(version: "1.0.0")
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 404, body: Data(),
                           delay: 0.3)
        let first = Task { await updater.check() }
        while updater.state != .checking { await Task.yield() }
        let second = await updater.check()
        XCTAssertNil(second, "a second check started while the first was in flight")
        let outcome = await first.value
        XCTAssertEqual(outcome, .nothingVisible)
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    @MainActor
    func testFailuresAreSaidInPlainWords() async {
        let updater = makeUpdater(version: "1.0.0")
        // No stub for the address: the stub answers as an unreachable host.
        await updater.check()
        XCTAssertEqual(updater.state, .failed("Couldn't reach GitHub."))
        XCTAssertEqual(updater.lastResult, "failed")

        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 403, body: Data())
        await updater.check()
        XCTAssertEqual(updater.state, .failed("GitHub is limiting requests for now."))

        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 502, body: Data())
        await updater.check()
        XCTAssertEqual(updater.state, .failed("GitHub answered with error 502."))

        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, body: Data("<html>".utf8))
        await updater.check()
        XCTAssertEqual(updater.state, .failed("GitHub's answer couldn't be read."))
    }

    @MainActor
    func testPretendVersionAndAnUnbundledBuild() throws {
        let pretend = makeUpdater(version: "0.9.0")
        XCTAssertEqual(pretend.currentVersion, "0.9.0")
        XCTAssertTrue(pretend.isPretending)
        XCTAssertEqual(makeUpdater(version: "v1.2.3").currentVersion, "1.2.3")
        // The test runner is not SolStream.app: it is never something to replace.
        XCTAssertNil(Updater.installableBundle(.main))

        // A bundle without a version is 0.0.0, which every release is newer
        // than; one with a version is that version.
        let bare = scratch.appendingPathComponent("Bare.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bare.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.bare"],
                                           format: .xml, options: 0)
            .write(to: bare.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(Updater.bundleVersion(try XCTUnwrap(Bundle(url: bare))), "0.0.0")
        let app = try makeInstalledApp(version: "1.4.2")
        XCTAssertEqual(Updater.bundleVersion(try XCTUnwrap(Bundle(url: app))), "1.4.2")
        XCTAssertEqual(Updater.installableBundle(try XCTUnwrap(Bundle(url: app)))?.standardizedFileURL,
                       app.standardizedFileURL)
    }

    @MainActor
    func testAutomaticChecksDefaultOnAndRespectTheSetting() async throws {
        let updater = makeUpdater(version: "1.0.0")
        XCTAssertTrue(updater.checksAutomatically)
        XCTAssertTrue(updater.isDue, "never checked is due")
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 404, body: Data())
        await updater.check()
        XCTAssertFalse(updater.isDue, "checked a moment ago")

        updater.checksAutomatically = false
        XCTAssertFalse(makeUpdater(version: "1.0.0").checksAutomatically, "remembered")
        StubProtocol.reset()
        updater.automaticCheck()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "checked with the setting off")
    }

    /// A check stamped while the clock ran ahead, the clock since put right,
    /// does not hold the daily check off until real time catches up.
    @MainActor
    func testAClockPutBackDoesNotStopTheDailyCheck() throws {
        let updater = makeUpdater(version: "1.0.0")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        for (offset, due) in [(-3600.0, false), (-25 * 3600.0, true), (3 * 24 * 3600.0, true)] {
            defaults.set(Date().addingTimeInterval(offset), forKey: "SolStream.update.lastCheck")
            XCTAssertEqual(updater.isDue, due, "last checked \(offset) s from now")
        }
    }

    /// `swift run` is a developer's build, at 0.0.0: it checks when asked,
    /// never by itself, unless a pretend version says the updater is the
    /// thing being tried.
    @MainActor
    func testABuildOutsideABundleChecksOnlyWhenAsked() async throws {
        let updater = makeUpdater(version: nil)
        XCTAssertFalse(updater.isPretending)
        XCTAssertFalse(updater.checksOnItsOwn)
        XCTAssertTrue(updater.checksAutomatically, "the setting itself is untouched")
        updater.automaticCheck()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "an unbundled build checked by itself")

        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 404, body: Data())
        let asked = await updater.check()
        XCTAssertEqual(asked, .nothingVisible)
        XCTAssertTrue(makeUpdater(version: "1.0.0").checksOnItsOwn)
        XCTAssertTrue(makeUpdater(version: nil, target: try makeInstalledApp(version: "1.0.0")).checksOnItsOwn)
    }

    // MARK: - Downloading

    @MainActor
    func testANewerReleaseIsDownloadedVerifiedAndReady() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)

        let outcome = await updater.check()
        guard case .newer(let found) = outcome else { return XCTFail("\(String(describing: outcome))") }
        XCTAssertEqual(found.version.text, "1.1.0")
        XCTAssertEqual(updater.state, .ready("1.1.0"))
        XCTAssertEqual(updater.statusText, "Update 1.1.0 is ready to install.")
        XCTAssertEqual(updater.announcedVersion, "1.1.0")
        let zip = try XCTUnwrap(updater.downloaded?.zip)
        XCTAssertEqual(ChecksumList.hex(SHA256.hash(data: try Data(contentsOf: zip))), release.digest)
        XCTAssertTrue(zip.path.hasPrefix(scratch.path), "downloaded outside the test's folder")

        // The public addresses, asking for the file itself.
        let assets = StubProtocol.requests.filter { $0.url?.host == "github.com" }
        XCTAssertEqual(assets.count, 3)
        for request in assets {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        }

        // A second check finds the same release and keeps the download.
        let requestsBefore = StubProtocol.requests.count
        await updater.check()
        XCTAssertEqual(updater.state, .ready("1.1.0"))
        XCTAssertEqual(StubProtocol.requests.count, requestsBefore + 1, "fetched the update again")
    }

    @MainActor
    func testDownloadsFollowGitHubsRedirectToStorage() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0", redirected: true)
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .ready("1.1.0"))

        let storage = StubProtocol.requests.filter { $0.url?.host == "objects.githubusercontent.com" }
        XCTAssertEqual(storage.count, 3, "each asset redirected to storage")
        for request in storage {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        }
    }

    @MainActor
    func testATamperedReleaseIsDiscardedNotInstalled() async throws {
        let target = try makeInstalledApp(version: "1.0.0")

        // Signed by somebody else.
        var release = try publish(version: "1.1.0")
        var updater = makeUpdater(version: "1.0.0", target: target, key: P256.Signing.PrivateKey()
            .publicKey.x963Representation.base64EncodedString())
        await updater.check()
        XCTAssertEqual(updater.state, .failed("The update's signature didn't verify."))
        XCTAssertNil(updater.downloaded)
        XCTAssertFalse(StubProtocol.requested(release.zipAddress), "fetched the archive before the signature held")

        // Signed, but the archive is not the one the sums describe.
        StubProtocol.reset()
        release = try publish(version: "1.1.0", corruptArchive: true)
        updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .failed("The download didn't match its checksum."))
        XCTAssertNil(updater.downloaded)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: downloadsFolder.path)) ?? []
        XCTAssertEqual(leftovers, [], "a download that failed its checksum was kept")

        // Signed, but the sums do not list this Mac's archive.
        StubProtocol.reset()
        release = try publish(version: "1.1.0", listedName: "SolStream-1.0.9-macOS.zip")
        updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .failed("The update's checksums didn't verify."))

        // Missing its archive altogether.
        StubProtocol.reset()
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString,
                           body: Self.releaseJSON(tag: "v1.1.0", assets: ["SHA256SUMS", "SHA256SUMS.sig"]))
        updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .failed("The release is missing a file."))

        // Larger than an update can be, by the release's own word.
        StubProtocol.reset()
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString,
                           body: Self.releaseJSON(tag: "v1.1.0", size: UpdateSource.maximumAssetBytes + 1))
        updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .failed("The download was too large to be an update."))

        XCTAssertEqual(try installedVersion(target), "1.0.0", "the installed copy was touched")
    }

    @MainActor
    func testNothingDownloadsDuringAStream() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        updater.isStreaming = true
        await updater.check()
        XCTAssertEqual(updater.state, .available("1.1.0"))
        XCTAssertEqual(updater.statusText, "Update 1.1.0 downloads after the stream.")
        XCTAssertFalse(StubProtocol.requested(release.zipAddress))
        // Asked for outright, it still waits.
        await updater.download()
        XCTAssertEqual(updater.state, .available("1.1.0"))
        XCTAssertFalse(StubProtocol.requested(release.zipAddress))

        let ready = expectation(description: "downloaded once the stream closed")
        let observer = NotificationCenter.default.addObserver(forName: Updater.didChange, object: updater,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated {
                if updater.state == .ready("1.1.0") { ready.fulfill() }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        updater.isStreaming = false
        await fulfillment(of: [ready], timeout: 10)
    }

    /// An update found during a stream, and so not yet downloaded, outlives a
    /// check that then fails: it is still announced, and still downloads
    /// when the stream closes, rather than wait a day for the next check.
    @MainActor
    func testAFailedRecheckKeepsAnUpdateAlreadyFound() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        updater.isStreaming = true
        await updater.check()
        XCTAssertEqual(updater.state, .available("1.1.0"))

        StubProtocol.serve(UpdateSource.latestRelease.absoluteString, status: 502, body: Data())
        let outcome = await updater.check()
        XCTAssertNil(outcome)
        XCTAssertEqual(updater.lastResult, "failed")
        XCTAssertEqual(updater.state, .available("1.1.0"))
        XCTAssertEqual(updater.announcedVersion, "1.1.0")

        updater.isStreaming = false
        await waitFor(updater) { $0 == .ready("1.1.0") }
    }

    /// A download already under way when a stream opens stops, rather than
    /// share the uplink with it, and starts again once the stream closes.
    @MainActor
    func testAStreamOpeningStopsADownloadUnderWay() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0", zipDelay: 1)
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        let checking = Task { await updater.check() }
        while !StubProtocol.requested(release.zipAddress) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(updater.state, .downloading("1.1.0", nil))
        updater.isStreaming = true
        _ = await checking.value
        XCTAssertEqual(updater.state, .available("1.1.0"))
        XCTAssertEqual(updater.statusText, "Update 1.1.0 downloads after the stream.")
        XCTAssertNil(updater.downloaded)
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: downloadsFolder.path)) ?? []
        XCTAssertEqual(leftovers, [], "a stopped download was kept")

        StubProtocol.serve(release.zipAddress, body: release.archive)
        updater.isStreaming = false
        await waitFor(updater) { $0 == .ready("1.1.0") }
        XCTAssertEqual(ChecksumList.hex(SHA256.hash(data: try Data(contentsOf: try XCTUnwrap(updater.downloaded?.zip)))),
                       release.digest)
    }

    /// A copy that cannot replace itself is offered the download as soon as
    /// it has one, not a button that can only fail; and showing it twice
    /// leaves it where the first time put it.
    @MainActor
    func testAnUnwritableFolderOffersTheDownloadStraightAway() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: target.deletingLastPathComponent().path)
        await updater.check()
        XCTAssertEqual(updater.state, .manualInstall("1.1.0", reason: "SolStream can't replace itself here."))

        try FileManager.default.createDirectory(at: revealFolder, withIntermediateDirectories: true)
        var shown: [URL] = []
        updater.showInFinder = { shown += $0 }
        updater.revealDownload()
        updater.revealDownload()
        let expected = revealFolder.appendingPathComponent("SolStream-1.1.0-macOS.zip").path
        XCTAssertEqual(shown.map(\.path), [expected, expected])
        XCTAssertEqual(updater.downloaded?.zip.path, expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: revealFolder.path),
                       ["SolStream-1.1.0-macOS.zip"])
        XCTAssertEqual(try installedVersion(target), "1.0.0")
    }

    // MARK: - Installing

    @MainActor
    func testInstallingSwapsTheBundleRelaunchesItAndTheNextLaunchTidiesUp() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .ready("1.1.0"))

        // Asked for during a stream, it waits for the stream to close.
        updater.isStreaming = true
        updater.installAndRelaunch()
        XCTAssertEqual(updater.state, .waitingForStream("1.1.0"))
        XCTAssertEqual(try installedVersion(target), "1.0.0")
        updater.cancelPendingInstall()
        XCTAssertEqual(updater.state, .ready("1.1.0"))
        updater.installAndRelaunch()
        XCTAssertEqual(updater.state, .waitingForStream("1.1.0"))
        XCTAssertEqual(updater.statusText, "Update 1.1.0 installs when the stream closes.")
        // A check meanwhile -- the menu's stays enabled -- leaves the promise
        // alone, so it cannot be put back after the stream has closed.
        let during = await updater.check()
        XCTAssertNil(during)
        XCTAssertEqual(updater.state, .waitingForStream("1.1.0"))

        var relaunched: [URL] = []
        let quit = expectation(description: "quit to make way for the new copy")
        updater.relaunch = { relaunched.append($0) }
        updater.terminate = { quit.fulfill() }
        updater.isStreaming = false
        await fulfillment(of: [quit], timeout: 30)

        XCTAssertEqual(relaunched, [target])
        XCTAssertEqual(try installedVersion(target), "1.1.0")
        let folder = target.deletingLastPathComponent()
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix(UpdateInstaller.replacedPrefix) }
        XCTAssertEqual(aside.count, 1, "the old copy is kept until the new one has started")

        // The next launch: the same defaults, the same bundle path.
        let next = makeUpdater(version: "1.1.0", target: target, key: release.publicKey)
        next.cleanUpAfterUpdate()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["SolStream.app"])
    }

    /// "Install when the stream closes" runs as it closes, and the picker is
    /// back a moment later: a stream opened while the install runs is not
    /// ended by the restart, which waits for that stream in turn.
    @MainActor
    func testAStreamOpenedDuringTheInstallPutsTheRestartOff() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        updater.installAndRelaunch()
        XCTAssertEqual(updater.state, .installing("1.1.0"))
        updater.isStreaming = true
        await waitFor(updater) { $0 == .installed("1.1.0") }
        XCTAssertEqual(try installedVersion(target), "1.1.0")
        XCTAssertEqual(updater.statusText,
                       "Update 1.1.0 is installed. Restarts after the stream.")
        let during = await updater.check()
        XCTAssertNil(during, "checked with the update already in place")

        var relaunched: [URL] = []
        var quits = 0
        updater.relaunch = { relaunched.append($0) }
        updater.terminate = { quits += 1 }
        updater.isStreaming = false
        XCTAssertEqual(relaunched, [target])
        XCTAssertEqual(quits, 1)
    }

    /// The archive waits in a folder anything running as this user can write
    /// to, for as long as the person takes to press Install: swapped there for
    /// another ad-hoc-signed SolStream, it is refused, not installed.
    @MainActor
    func testADownloadSwappedAfterItWasVerifiedIsRefused() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .ready("1.1.0"))

        let cached = try XCTUnwrap(updater.downloaded?.zip)
        let impostor = try makeZip(version: "1.1.0", payload: "not the release")
        try FileManager.default.removeItem(at: cached)
        try FileManager.default.copyItem(at: impostor, to: cached)
        updater.installAndRelaunch()
        await waitFor(updater) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(updater.state, .failed("The download didn't match its checksum."))
        XCTAssertNil(updater.downloaded)
        XCTAssertEqual(try installedVersion(target), "1.0.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path), ["SolStream.app"])
    }

    /// SOLSTREAM_PRETEND_VERSION can make the check find the version already
    /// installed, but the install itself still refuses to go sideways.
    @MainActor
    func testAPretendVersionNeverInstallsOverTheSameVersion() async throws {
        let target = try makeInstalledApp(version: "1.1.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .ready("1.1.0"))
        updater.installAndRelaunch()
        await waitFor(updater) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(updater.state, .failed("This copy is already up to date."))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path), ["SolStream.app"])
    }

    @MainActor
    func testTheTidyingUpDeletesOnlyWhatTheUpdaterSetAside() throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let elsewhere = scratch.appendingPathComponent("Other/\(UpdateInstaller.replacedPrefix)x.app")
        let misnamed = target.deletingLastPathComponent().appendingPathComponent("Keep me.app")
        for folder in [elsewhere, misnamed] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults.set(folder.path, forKey: "SolStream.update.replacedBundle")
            makeUpdater(version: "1.0.0", target: target).cleanUpAfterUpdate()
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), folder.path)
            XCTAssertNil(defaults.string(forKey: "SolStream.update.replacedBundle"))
        }
    }

    func testTheInstallerChecksIdentityVersionAndSignature() throws {
        let target = try makeInstalledApp(version: "1.0.0")

        let wrongVersion = try makeZip(version: "1.1.1")
        XCTAssertThrowsError(try install(wrongVersion, version: "1.1.0", replacing: target)) {
            XCTAssertEqual($0 as? UpdateInstaller.Failure, .wrongVersion("1.1.1"))
        }
        let wrongIdentity = try makeZip(version: "1.1.0", identifier: "com.example.other")
        XCTAssertThrowsError(try install(wrongIdentity, version: "1.1.0", replacing: target)) {
            XCTAssertEqual($0 as? UpdateInstaller.Failure, .wrongIdentifier("com.example.other"))
        }
        let resealed = try makeZip(version: "1.1.0", tamperAfterSigning: true)
        XCTAssertThrowsError(try install(resealed, version: "1.1.0", replacing: target)) {
            guard case .signatureRejected? = $0 as? UpdateInstaller.Failure else {
                return XCTFail("\($0)")
            }
        }
        let notAZip = scratch.appendingPathComponent("not.zip")
        try Data("PK? no".utf8).write(to: notAZip)
        XCTAssertThrowsError(try install(notAZip, version: "1.1.0", replacing: target)) {
            guard case .unpackFailed? = $0 as? UpdateInstaller.Failure else { return XCTFail("\($0)") }
        }
        let empty = try makeZip(containing: [])
        XCTAssertThrowsError(try install(empty, version: "1.1.0", replacing: target)) {
            XCTAssertEqual($0 as? UpdateInstaller.Failure, .notAnApp)
        }
        // A good archive, but not the one the sums were for.
        let good = try makeZip(version: "1.1.0")
        XCTAssertThrowsError(try UpdateInstaller.install(zip: good, sha256: String(repeating: "0", count: 64),
                                                         version: "1.1.0", replacing: target)) {
            XCTAssertEqual($0 as? UpdateInstaller.Failure, .checksumMismatch)
        }

        XCTAssertEqual(try installedVersion(target), "1.0.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(
            atPath: target.deletingLastPathComponent().path), ["SolStream.app"],
                       "a refused install left something behind")
    }

    /// ditto, codesign and the relaunch shell are started with a fixed PATH
    /// and only the names that say who the user is.
    func testTheToolsTheInstallerStartsGetAFixedEnvironment() {
        let environment = UpdateInstaller.toolEnvironment(from: [
            "SOLSTREAM_PRETEND_VERSION": "9.9.9", "HOME": "/Users/someone",
            "PATH": "/tmp/elsewhere:/usr/bin", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib",
        ])
        XCTAssertEqual(environment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/Users/someone"])
    }

    /// Never sideways and never down, measured against the bundle being
    /// replaced: SOLSTREAM_PRETEND_VERSION fools the check, not the install.
    func testTheInstallerOnlyMovesToANewerVersion() throws {
        let target = try makeInstalledApp(version: "1.1.0")
        for version in ["1.1.0", "1.0.9"] {
            let zip = try makeZip(version: version)
            XCTAssertThrowsError(try install(zip, version: version, replacing: target), version) {
                XCTAssertEqual($0 as? UpdateInstaller.Failure, .notNewer("1.1.0"))
            }
        }
        XCTAssertEqual(try installedVersion(target), "1.1.0")
        XCTAssertNoThrow(try install(try makeZip(version: "1.1.1"), version: "1.1.1", replacing: target))
        XCTAssertEqual(try installedVersion(target), "1.1.1")
    }

    func testAFolderThatCannotBeWrittenIsSaidNotForced() throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let zip = try makeZip(version: "1.1.0")
        let folder = target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        XCTAssertFalse(UpdateInstaller.canReplace(target))
        XCTAssertThrowsError(try install(zip, version: "1.1.0", replacing: target)) {
            XCTAssertEqual($0 as? UpdateInstaller.Failure, .notWritable(folder))
        }
        XCTAssertEqual(try installedVersion(target), "1.0.0")
        XCTAssertFalse(UpdateInstaller.canReplace(scratch.appendingPathComponent("Missing.app")))
    }

    func testTheInstallerWorksOnAnyFolderAndKeepsTheOldCopyAside() throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let zip = try makeZip(version: "1.1.0")
        let aside = try install(zip, version: "1.1.0", replacing: target)
        XCTAssertEqual(try installedVersion(target), "1.1.0")
        XCTAssertEqual(aside.deletingLastPathComponent().standardizedFileURL,
                       target.deletingLastPathComponent().standardizedFileURL)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix(UpdateInstaller.replacedPrefix))
        XCTAssertEqual(try installedVersion(aside), "1.0.0")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: aside.appendingPathComponent("Contents/Resources/old-marker").path))
    }

    @MainActor
    func testAnUnwritableInstallOffersTheDownloadInstead() async throws {
        let target = try makeInstalledApp(version: "1.0.0")
        let release = try publish(version: "1.1.0")
        let updater = makeUpdater(version: "1.0.0", target: target, key: release.publicKey)
        await updater.check()
        XCTAssertEqual(updater.state, .ready("1.1.0"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: target.deletingLastPathComponent().path)
        updater.terminate = { XCTFail("quit without installing") }
        updater.relaunch = { _ in XCTFail("relaunched without installing") }
        let settled = expectation(description: "the install gave up")
        let observer = NotificationCenter.default.addObserver(forName: Updater.didChange, object: updater,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated {
                if case .manualInstall = updater.state { settled.fulfill() }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        updater.installAndRelaunch()
        await fulfillment(of: [settled], timeout: 30)
        XCTAssertEqual(updater.state, .manualInstall("1.1.0", reason: "SolStream can't replace itself here."))
        XCTAssertNotNil(updater.downloaded, "the download is kept, to be shown")
        XCTAssertEqual(try installedVersion(target), "1.0.0")
    }

    // MARK: - Helpers

    private static func stubbed() -> URLSessionConfiguration {
        let configuration = UpdateTransport.defaultConfiguration()
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    /// Where the updater keeps what it downloads, in place of the real Caches.
    /// Named unlike `revealFolder` by more than case: on a case-insensitive
    /// disk -- macOS's default, and CI's -- "downloads" and "Downloads" are
    /// the same folder, and showing the download would rightly not move it.
    private var downloadsFolder: URL { scratch.appendingPathComponent("update-cache", isDirectory: true) }

    /// Where "Show download" puts the archive in these tests, in place of the
    /// real Downloads.
    private var revealFolder: URL { scratch.appendingPathComponent("Downloads", isDirectory: true) }

    @MainActor
    private func makeUpdater(version: String?, target: URL? = nil,
                             key: String = UpdateSignature.productionKey) -> Updater {
        var environment: [String: String] = [:]
        environment["SOLSTREAM_PRETEND_VERSION"] = version
        let updater = Updater(defaults: UserDefaults(suiteName: suiteName)!,
                              configuration: Self.stubbed(), environment: environment,
                              bundle: Bundle(for: UpdaterTests.self), installTarget: target,
                              publicKey: key,
                              downloadsFolder: downloadsFolder,
                              revealFolder: revealFolder)
        updater.relaunch = { _ in XCTFail("a test tried to relaunch") }
        updater.terminate = { XCTFail("a test tried to quit") }
        updater.showInFinder = { _ in XCTFail("a test tried to open Finder") }
        return updater
    }

    /// The installer, given the archive's real hash, as the sums would.
    @discardableResult
    private func install(_ zip: URL, version: String, replacing target: URL) throws -> URL {
        let sha256 = ChecksumList.hex(SHA256.hash(data: try Data(contentsOf: zip)))
        return try UpdateInstaller.install(zip: zip, sha256: sha256, version: version, replacing: target)
    }

    /// A release served by the stub, signed with a key made for it. Returns
    /// the key, what the sums say, and the archive as served.
    private struct Published {
        let publicKey: String
        let digest: String
        let zipAddress: String
        let archive: Data
    }

    private func publish(version: String, redirected: Bool = false, corruptArchive: Bool = false,
                         listedName: String? = nil, zipDelay: TimeInterval = 0) throws -> Published {
        let zip = try makeZip(version: version)
        var archive = try Data(contentsOf: zip)
        let digest = ChecksumList.hex(SHA256.hash(data: archive))
        let zipName = UpdateSource.zipName(for: version)
        let sums = Data("\(digest)  \(listedName ?? zipName)\n\(String(repeating: "0", count: 64))  SolStreamSetup-\(version).exe\n".utf8)
        let key = P256.Signing.PrivateKey()
        let signature = Data((try key.signature(for: sums).rawRepresentation.base64EncodedString() + "\n").utf8)
        if corruptArchive { archive[archive.count / 2] ^= 0xFF }

        let tag = "v\(version)"
        StubProtocol.serve(UpdateSource.latestRelease.absoluteString,
                           body: Self.releaseJSON(tag: tag, size: Int64(archive.count)))
        let files: [(String, Data)] = [(zipName, archive), ("SHA256SUMS", sums), ("SHA256SUMS.sig", signature)]
        var zipAddress = ""
        for (index, (name, data)) in files.enumerated() {
            let download = "https://github.com/Bruno-Alumn/SolStream/releases/download/\(tag)/\(name)"
            let storage = "https://objects.githubusercontent.com/github-production-release-asset/\(index + 1)?sig=x"
            let delay = name == zipName ? zipDelay : 0
            if redirected {
                // As GitHub does: the download address redirects to storage.
                StubProtocol.redirect(download, to: storage)
                StubProtocol.serve(storage, body: data, delay: delay)
                if name == zipName { zipAddress = storage }
            } else {
                StubProtocol.serve(download, body: data, delay: delay)
                if name == zipName { zipAddress = download }
            }
        }
        return Published(publicKey: key.publicKey.x963Representation.base64EncodedString(),
                         digest: digest, zipAddress: zipAddress, archive: archive)
    }

    /// Wait, on the main actor, for the updater to reach a state.
    @MainActor
    private func waitFor(_ updater: Updater, timeout: TimeInterval = 30,
                         _ matches: @escaping (Updater.State) -> Bool) async {
        guard !matches(updater.state) else { return }
        let reached = expectation(description: "the updater reached the state")
        reached.assertForOverFulfill = false
        let observer = NotificationCenter.default.addObserver(forName: Updater.didChange, object: updater,
                                                              queue: .main) { _ in
            MainActor.assumeIsolated {
                if matches(updater.state) { reached.fulfill() }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        await fulfillment(of: [reached], timeout: timeout)
    }

    /// The JSON `releases/latest` answers with. The archive is asset 1 and
    /// the sums and signature 2 and 3, as `publish` serves them.
    static func releaseJSON(tag: String, draft: Bool = false, prerelease: Bool = false,
                            size: Int64 = 1234, assets: [String]? = nil) -> Data {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let names = assets ?? ["SolStream-\(version)-macOS.zip", "SHA256SUMS", "SHA256SUMS.sig",
                               "SolStream-\(version)-macOS.dmg", "SolStreamSetup-\(version).exe"]
        let list = names.enumerated().map { index, name -> [String: Any] in
            ["name": name, "size": name.hasSuffix(".zip") ? size : 100,
             "browser_download_url": "https://github.com/Bruno-Alumn/SolStream/releases/download/\(tag)/\(name)"]
        }
        let release: [String: Any] = ["tag_name": tag, "draft": draft, "prerelease": prerelease,
                                      "name": "SolStream \(version)", "assets": list]
        return try! JSONSerialization.data(withJSONObject: release)
    }

    /// `Apps/SolStream.app` at `version`, ad-hoc signed, as an install looks.
    private func makeInstalledApp(version: String) throws -> URL {
        let folder = scratch.appendingPathComponent("Apps", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let app = try makeBundle(in: folder, version: version)
        try Data("old".utf8).write(to: app.appendingPathComponent("Contents/Resources/old-marker"))
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    private func makeBundle(in folder: URL, version: String,
                            identifier: String = UpdateSource.bundleIdentifier) throws -> URL {
        let app = folder.appendingPathComponent("SolStream.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"),
                                                withIntermediateDirectories: true)
        // Any real executable will do for the signature to seal.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"),
                                         to: macOS.appendingPathComponent("SolStream"))
        let plist: [String: Any] = ["CFBundleExecutable": "SolStream", "CFBundleIdentifier": identifier,
                                    "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    /// A release archive as the pipeline makes it: `ditto -c -k --keepParent`.
    private func makeZip(version: String, identifier: String = UpdateSource.bundleIdentifier,
                         payload: String? = nil, tamperAfterSigning: Bool = false) throws -> URL {
        let staging = scratch.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let app = try makeBundle(in: staging, version: version, identifier: identifier)
        if let payload {
            try Data(payload.utf8).write(to: app.appendingPathComponent("Contents/Resources/payload"))
        }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        if tamperAfterSigning {
            try Data("added after signing".utf8)
                .write(to: app.appendingPathComponent("Contents/Resources/extra"))
        }
        return try makeZip(containing: [app])
    }

    private func makeZip(containing items: [URL]) throws -> URL {
        let zip = scratch.appendingPathComponent("release-\(UUID().uuidString).zip")
        if items.isEmpty {
            let empty = scratch.appendingPathComponent("empty-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            try Data("not an app".utf8).write(to: empty.appendingPathComponent("README"))
            try run("/usr/bin/ditto", ["-c", "-k", empty.path, zip.path])
        } else {
            try run("/usr/bin/ditto", ["-c", "-k", "--keepParent"] + items.map(\.path) + [zip.path])
        }
        return zip
    }

    private func installedVersion(_ app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleShortVersionString"] as? String
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UpdaterTests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(tool) failed: \(output)"])
        }
        return output
    }
}

/// GitHub, as far as the updater can tell: canned answers by address, and a
/// record of every request, headers and all. An address with no answer fails
/// as an unreachable host does.
final class StubProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var redirect: URL?
        /// How long GitHub takes to answer.
        var delay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    static func requested(_ address: String) -> Bool {
        requests.contains { $0.url?.absoluteString == address }
    }

    static func reset() {
        lock.lock()
        replies = [:]
        recorded = []
        lock.unlock()
    }

    static func serve(_ address: String, status: Int = 200, body: Data, headers: [String: String] = [:],
                      delay: TimeInterval = 0) {
        lock.lock()
        replies[address] = Reply(status: status, headers: headers, body: body, delay: delay)
        lock.unlock()
    }

    static func redirect(_ address: String, to target: String) {
        lock.lock()
        replies[address] = Reply(status: 302, headers: ["Location": target], redirect: URL(string: target))
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recorded.append(request)
        let reply = Self.replies[url.absoluteString]
        Self.lock.unlock()

        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = "\(reply.body.count)" }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        if let target = reply.redirect {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        // On the protocol's own thread, which is not the main one.
        if reply.delay > 0 { Thread.sleep(forTimeInterval: reply.delay) }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
