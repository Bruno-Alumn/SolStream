import Security
import XCTest
@testable import AgentChannel

/// The pairing token store: a 0600 file, never a prompt, and tokens from older
/// builds moved across.
final class TokenStoreTests: XCTestCase {
    private var directory: URL!
    private let host = "token-store-test.invalid"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-tokens-\(UUID().uuidString)", isDirectory: true)
        TokenStore.directoryOverride = directory
        TokenStore.namesDefaults = UserDefaults(
            suiteName: directory.appendingPathComponent("names").path)!
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "SolStream.agentToken.\(host)")
        TokenStore.directoryOverride = nil
        TokenStore.namesDefaults.removePersistentDomain(
            forName: directory.appendingPathComponent("names").path)
        TokenStore.namesDefaults = .standard
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testATokenRoundTripsAndOnlyThisUserCanReadIt() throws {
        XCTAssertFalse(TokenStore.hasToken(for: host))
        TokenStore.set("00112233445566778899aabbccddeeff", for: host)
        XCTAssertTrue(TokenStore.hasToken(for: host))
        XCTAssertEqual(TokenStore.token(for: host), "00112233445566778899aabbccddeeff")

        let attributes = try FileManager.default.attributesOfItem(atPath: TokenStore.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let excluded = try TokenStore.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(excluded.isExcludedFromBackup, true)
    }

    func testItSurvivesARestartOfTheProcess() {
        TokenStore.set("00112233445566778899aabbccddeef0", for: host)
        // Dropping the in-memory copy is what a new launch looks like.
        TokenStore.directoryOverride = directory
        XCTAssertEqual(TokenStore.token(for: host), "00112233445566778899aabbccddeef0")
    }

    func testATokenFromAnOlderBuildIsMovedOutOfPreferences() {
        UserDefaults.standard.set("00112233445566778899aabbccddeeff",
                                  forKey: "SolStream.agentToken.\(host)")
        XCTAssertTrue(TokenStore.hasToken(for: host))
        XCTAssertEqual(TokenStore.token(for: host), "00112233445566778899aabbccddeeff")
        XCTAssertNil(UserDefaults.standard.string(forKey: "SolStream.agentToken.\(host)"),
                     "the plain-text copy should be gone once moved")
        TokenStore.directoryOverride = directory
        XCTAssertEqual(TokenStore.token(for: host), "00112233445566778899aabbccddeeff")
    }

    /// An older build's token is not deleted when the new store cannot be
    /// written: it would be gone with the run, and the Mac unpaired.
    func testATokenThatCouldNotBeMovedStaysWhereItWas() throws {
        let readOnly = directory.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o500])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: readOnly.path)
        }
        TokenStore.directoryOverride = readOnly
        let key = "SolStream.agentToken.\(host)"
        UserDefaults.standard.set("00112233445566778899aabbccddeeff", forKey: key)

        XCTAssertEqual(TokenStore.token(for: host), "00112233445566778899aabbccddeeff",
                       "this run lost the token")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TokenStore.fileURL.path))
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "00112233445566778899aabbccddeeff",
                       "the only lasting copy was deleted")

        // Writable again, the next run moves it.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path)
        TokenStore.directoryOverride = readOnly
        XCTAssertEqual(TokenStore.token(for: host), "00112233445566778899aabbccddeeff")
        XCTAssertNil(UserDefaults.standard.string(forKey: key))
    }

    /// Whether this Mac has paired with anything at all, which decides the
    /// connect window's first-run guide. Measured against what is there
    /// before the test, rather than asserted false: a Mac that ran a keychain
    /// build may still hold an old item, and that rightly counts.
    func testAnyTokenAtAllCounts() {
        let before = TokenStore.hasAnyToken
        TokenStore.set("00112233445566778899aabbccddeeff", for: host)
        XCTAssertTrue(TokenStore.hasAnyToken)
        TokenStore.remove(for: host)
        XCTAssertEqual(TokenStore.hasAnyToken, before)
    }

    func testAnOlderBuildsTokenInPreferencesCounts() {
        UserDefaults.standard.set("00112233445566778899aabbccddeeff",
                                  forKey: "SolStream.agentToken.\(host)")
        XCTAssertTrue(TokenStore.hasAnyToken)
    }

    /// A keychain that cannot answer now -- locked, its daemon busy -- is
    /// asked again next time; only one that says "none" is taken at its word.
    func testOnlyANoFromTheKeychainIsRemembered() {
        var status = errSecInteractionNotAllowed
        TokenStore.keychainLookup = { _ in status }
        defer { TokenStore.keychainLookup = { SecItemCopyMatching($0 as CFDictionary, nil) } }

        XCTAssertFalse(TokenStore.hasToken(for: host))
        XCTAssertFalse(TokenStore.hasAnyToken)
        status = errSecSuccess
        XCTAssertTrue(TokenStore.hasToken(for: host), "a passing error was remembered as unpaired")
        XCTAssertTrue(TokenStore.hasAnyToken, "a passing error was remembered as never paired")

        TokenStore.directoryOverride = directory
        status = errSecItemNotFound
        XCTAssertFalse(TokenStore.hasToken(for: host))
        XCTAssertFalse(TokenStore.hasAnyToken)
        status = errSecSuccess
        XCTAssertFalse(TokenStore.hasToken(for: host), "a definite no was asked again")
        XCTAssertFalse(TokenStore.hasAnyToken, "a definite no was asked again")
    }

    func testRemovingForgetsIt() {
        TokenStore.set("00112233445566778899aabbccddeeff", for: host)
        TokenStore.remove(for: host)
        XCTAssertFalse(TokenStore.hasToken(for: host))
        XCTAssertNil(TokenStore.token(for: host))
    }

    /// A token is found by the PC's name at any of its addresses -- in any
    /// case -- but never when two PCs by that name hold different ones.
    func testATokenIsFoundByThePCsName() {
        TokenStore.set("00112233445566778899aabbccddee01", for: "192.168.1.21")
        TokenStore.setName("DESKTOP-PC", for: "192.168.1.21")
        XCTAssertEqual(TokenStore.token(forPCNamed: "desktop-pc"), "00112233445566778899aabbccddee01")
        XCTAssertTrue(TokenStore.hasToken(forPCNamed: "DESKTOP-PC"))
        XCTAssertNil(TokenStore.token(forPCNamed: "LAPTOP"))
        // The same PC on Wi-Fi too, same token: still one answer.
        TokenStore.set("00112233445566778899aabbccddee01", for: "192.168.1.40")
        TokenStore.setName("DESKTOP-PC", for: "192.168.1.40")
        XCTAssertEqual(TokenStore.token(forPCNamed: "DESKTOP-PC"), "00112233445566778899aabbccddee01")
        // A second PC by that name with its own token: no guess.
        TokenStore.set("00112233445566778899aabbccddee02", for: "10.0.0.9")
        TokenStore.setName("DESKTOP-PC", for: "10.0.0.9")
        XCTAssertNil(TokenStore.token(forPCNamed: "DESKTOP-PC"))
        XCTAssertFalse(TokenStore.hasToken(forPCNamed: "DESKTOP-PC"))
        // Forgotten with its address, and with everything.
        TokenStore.remove(for: "10.0.0.9")
        XCTAssertEqual(TokenStore.token(forPCNamed: "DESKTOP-PC"), "00112233445566778899aabbccddee01")
        TokenStore.removeAll()
        XCTAssertNil(TokenStore.token(forPCNamed: "DESKTOP-PC"))
    }
}

/// Names written two ways are one PC to the store and to the recent list.
final class HostVariantTests: XCTestCase {
    /// A test that sets no override never reaches the person's real store:
    /// one once ran `removeAll()` against it.
    func testATestWithoutAnOverrideHasAStoreOfItsOwn() {
        XCTAssertNil(TokenStore.directoryOverride)
        XCTAssertTrue(TokenStore.unguardedTest)
        XCTAssertFalse(TokenStore.fileURL.path.contains("Application Support"),
                       TokenStore.fileURL.path)
        XCTAssertTrue(TokenStore.fileURL.path.hasPrefix(
            FileManager.default.temporaryDirectory.path))
    }

    func testCaseAndATrailingDotAreTheSameHost() {
        XCTAssertTrue(TokenStore.sameHost("PC.local", "pc.local."))
        XCTAssertTrue(TokenStore.sameHost("Gaming-PC", "gaming-pc"))
        XCTAssertFalse(TokenStore.sameHost("pc.local", "pc2.local"))
    }
}
