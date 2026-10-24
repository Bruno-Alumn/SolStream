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
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "SolStream.agentToken.\(host)")
        TokenStore.directoryOverride = nil
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
}
