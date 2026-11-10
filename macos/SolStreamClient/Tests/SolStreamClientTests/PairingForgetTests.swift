import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// Forget Pairing forgets one PC -- every address it was paired at under its
/// name -- and leaves the others paired. Isolated as TokenStoreTests is: a
/// test once wiped the real pairing tokens.
final class PairingForgetTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let token = "00112233445566778899aabbccddeeff"

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-forget-\(UUID().uuidString)", isDirectory: true)
        TokenStore.directoryOverride = directory
        TokenStore.namesDefaults = UserDefaults(
            suiteName: directory.appendingPathComponent("names").path)!
        defaults = UserDefaults(suiteName: directory.appendingPathComponent("prefs").path)!
    }

    override func tearDown() {
        TokenStore.directoryOverride = nil
        TokenStore.namesDefaults.removePersistentDomain(
            forName: directory.appendingPathComponent("names").path)
        TokenStore.namesDefaults = .standard
        defaults.removePersistentDomain(forName: directory.appendingPathComponent("prefs").path)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testOnePCIsForgottenAtEveryAddressItHadAndNoOtherIs() {
        TokenStore.set(token, for: "desk-wifi.invalid")
        TokenStore.setName("DESK", for: "desk-wifi.invalid")
        TokenStore.set(token, for: "desk-wired.invalid")
        TokenStore.setName("DESK", for: "desk-wired.invalid")
        TokenStore.set(token, for: "laptop.invalid")
        TokenStore.setName("LAPTOP", for: "laptop.invalid")

        let hosts = PairingForget.hosts(address: "desk-wifi.invalid", name: "desk")
        XCTAssertEqual(Set(hosts), ["desk-wifi.invalid", "desk-wired.invalid"])
        PairingForget.forget(hosts: hosts, removingLaunchers: false, defaults: defaults)

        XCTAssertFalse(TokenStore.hasToken(for: "desk-wifi.invalid"))
        XCTAssertFalse(TokenStore.hasToken(for: "desk-wired.invalid"))
        XCTAssertFalse(TokenStore.hasToken(forPCNamed: "DESK"))
        XCTAssertTrue(TokenStore.hasToken(for: "laptop.invalid"), "another PC stays paired")
    }

    /// Two PCs by one name, each with its own token, are two PCs.
    func testAnotherPCByTheSameNameStaysPaired() {
        TokenStore.set(token, for: "gaming-desk.invalid")
        TokenStore.setName("GAMING", for: "gaming-desk.invalid")
        TokenStore.set("00112233445566778899aabbccddeef0", for: "gaming-laptop.invalid")
        TokenStore.setName("GAMING", for: "gaming-laptop.invalid")
        let hosts = PairingForget.hosts(address: "gaming-desk.invalid", name: "GAMING")
        XCTAssertEqual(hosts, ["gaming-desk.invalid"])
        PairingForget.forget(hosts: hosts, removingLaunchers: false, defaults: defaults)
        XCTAssertTrue(TokenStore.hasToken(for: "gaming-laptop.invalid"))
    }

    /// A used-before row has no name of its own; the one its greeting gave
    /// finds the PC's other addresses.
    func testAUsedBeforeRowFindsThePCsOtherAddresses() {
        TokenStore.set(token, for: "desk-wifi.invalid")
        TokenStore.setName("DESK", for: "desk-wifi.invalid")
        TokenStore.set(token, for: "desk-wired.invalid")
        TokenStore.setName("DESK", for: "desk-wired.invalid")
        XCTAssertEqual(Set(PairingForget.hosts(address: "desk-wifi.invalid", name: nil)),
                       ["desk-wifi.invalid", "desk-wired.invalid"])
    }

    func testAnAddressAloneIsItsOwnPC() {
        XCTAssertEqual(PairingForget.hosts(address: "192.0.2.4", name: nil), ["192.0.2.4"])
    }

    /// What reopens at launch is forgotten with its PC, and only with it.
    func testTheLastAppGoesWithItsPC() {
        AppLink.setLast(AppLink(host: "laptop.invalid", name: "Notepad"), in: defaults)
        PairingForget.forget(hosts: ["desk.invalid"], removingLaunchers: false, defaults: defaults)
        XCTAssertNotNil(AppLink.last(in: defaults))
        PairingForget.forget(hosts: ["LAPTOP.invalid"], removingLaunchers: false, defaults: defaults)
        XCTAssertNil(AppLink.last(in: defaults))
    }

    func testTheQuestionNamesThePC() {
        XCTAssertEqual(ConnectWindow.forgetPairingQuestion("DESK"), "Forget the pairing with DESK?")
        XCTAssertTrue(ConnectWindow.forgetPairingDetail.contains("Other PCs stay paired."))
    }
}
