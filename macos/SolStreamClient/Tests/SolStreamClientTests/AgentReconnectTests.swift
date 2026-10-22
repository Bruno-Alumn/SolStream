import XCTest
@testable import AgentChannel

/// Coming back to a host that is still holding this Mac's last connection: when
/// to go on knocking, and how to ask for the session back.
final class AgentReconnectTests: XCTestCase {

    // MARK: - Busy

    func testBusyFromAHostThatCannotSayIsFinalOnAFirstConnection() {
        XCTAssertEqual(AgentConnection.busyAction(holder: .unknown, reconnecting: false,
                                                  waited: 0, retries: 0), .giveUp,
                       "a Mac connecting afresh to a busy host is turned away by another Mac")
    }

    func testBusyWhileReconnectingIsWaitedOutForABoundedTime() {
        // The host has not yet noticed this Mac's last connection is dead: it
        // lets go within its 30-second idle timeout.
        for waited in [0.0, 2, 10, 29, 44.9] {
            guard case .retry = AgentConnection.busyAction(holder: .unknown, reconnecting: true,
                                                           waited: waited, retries: 3) else {
                return XCTFail("gave up \(waited)s after the session was lost")
            }
        }
        XCTAssertEqual(AgentConnection.busyAction(holder: .unknown, reconnecting: true,
                                                  waited: AgentConnection.busyPatience,
                                                  retries: 3), .giveUp)
        XCTAssertEqual(AgentConnection.busyAction(holder: .unknown, reconnecting: true,
                                                  waited: 600, retries: 0), .giveUp,
                       "busy long after the loss is somebody else, not this Mac's old session")
        XCTAssertGreaterThan(AgentConnection.busyPatience, 30,
                             "the wait must outlast the host's own idle timeout")
    }

    func testAHostThatNamesAnotherMacIsFinalEvenWhileReconnecting() {
        XCTAssertEqual(AgentConnection.busyAction(holder: .anotherMac, reconnecting: true,
                                                  waited: 0, retries: 0), .giveUp)
        XCTAssertEqual(AgentConnection.busyAction(holder: .anotherMac, reconnecting: false,
                                                  waited: 0, retries: 0), .giveUp)
    }

    func testAHostThatNamesThisMacIsWaitedForOnAnyConnection() {
        // Back pressed during a slow launch, and the same PC chosen again: the
        // host has not read the close yet. Not "another Mac".
        guard case .retry = AgentConnection.busyAction(holder: .thisMac, reconnecting: false,
                                                       waited: 1, retries: 0) else {
            return XCTFail("a host letting go of this Mac's own session was not waited for")
        }
        XCTAssertEqual(AgentConnection.busyAction(holder: .thisMac, reconnecting: false,
                                                  waited: AgentConnection.busyPatience,
                                                  retries: 9), .giveUp,
                       "not for ever: a second copy of the app may be holding it live")
    }

    func testBusyRetriesBackOffAndStayShort() {
        let delays = (0..<8).map { retries -> TimeInterval in
            guard case .retry(let delay) = AgentConnection.busyAction(
                holder: .unknown, reconnecting: true, waited: 1, retries: retries) else {
                XCTFail("gave up at retry \(retries)")
                return 0
            }
            return delay
        }
        XCTAssertEqual(delays.first, 2)
        XCTAssertEqual(delays, delays.sorted(), "never sooner than the time before")
        XCTAssertEqual(delays.last, 6, "capped, so the wait ends soon after the host lets go")
        XCTAssertTrue(delays.allSatisfy { $0 >= 2 && $0 <= 6 })
    }

    func testTheHoldersNameIsReadAndAnythingElseIsUnknown() {
        XCTAssertEqual(AgentConnection.BusyHolder(field: "self"), .thisMac)
        XCTAssertEqual(AgentConnection.BusyHolder(field: "other"), .anotherMac)
        XCTAssertEqual(AgentConnection.BusyHolder(field: nil), .unknown)
        XCTAssertEqual(AgentConnection.BusyHolder(field: "someone"), .unknown)
        XCTAssertEqual(AgentConnection.BusyHolder(field: 1), .unknown)
    }

    // MARK: - Takeover

    /// The same frozen vector as the host's TestTakeoverProof, so a change to
    /// what either end HMACs fails a test rather than every takeover.
    private let token = "00112233445566778899aabbccddeeff"
    private let challenge = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let clientNonce = Data((32..<64).map { UInt8($0) })
    private let clientID = "0123456789abcdef0123456789abcdef"

    func testTakeoverProofMatchesTheHostsVector() throws {
        let proof = try XCTUnwrap(AgentConnection.takeoverProof(
            token: token, challenge: challenge, clientNonce: clientNonce, clientID: clientID))
        XCTAssertEqual(AgentConnection.hex(proof),
                       "2e9724ecddb956360f9455f33d31d1157c2a3d13aac41a4c8085879862b2bc38")
        let other = try XCTUnwrap(AgentConnection.takeoverProof(
            token: token, challenge: challenge, clientNonce: clientNonce,
            clientID: "fedcba9876543210fedcba9876543210"))
        XCTAssertNotEqual(other, proof, "the id is inside the proof")
    }

    func testTakeoverRequestCarriesTheIdTheNonceAndTheProof() throws {
        let request = try XCTUnwrap(AgentConnection.takeoverRequest(
            token: token, challenge: challenge, clientNonce: clientNonce, clientID: clientID))
        XCTAssertEqual(request["cmd"] as? String, "takeover")
        XCTAssertEqual(request["client"] as? String, clientID)
        XCTAssertEqual(request["cnonce"] as? String, AgentConnection.hex(clientNonce))
        XCTAssertEqual(request["proof"] as? String,
                       "2e9724ecddb956360f9455f33d31d1157c2a3d13aac41a4c8085879862b2bc38")
        // The token itself never goes.
        XCTAssertFalse(request.values.contains { ($0 as? String) == token })
    }

    func testNoTakeoverProofFromMalformedInputs() {
        XCTAssertNil(AgentConnection.takeoverProof(token: "", challenge: challenge,
                                                   clientNonce: clientNonce, clientID: clientID))
        XCTAssertNil(AgentConnection.takeoverProof(token: "not hex", challenge: challenge,
                                                   clientNonce: clientNonce, clientID: clientID))
        XCTAssertNil(AgentConnection.takeoverProof(token: token, challenge: String(challenge.dropLast(2)),
                                                   clientNonce: clientNonce, clientID: clientID))
        XCTAssertNil(AgentConnection.takeoverProof(token: token, challenge: challenge,
                                                   clientNonce: Data(count: 16), clientID: clientID))
        XCTAssertNil(AgentConnection.takeoverProof(token: token, challenge: challenge,
                                                   clientNonce: clientNonce, clientID: "ABC"))
    }

    // MARK: - Client id

    func testClientIDIsMadeOnceAndKept() throws {
        // A path, not a name: a named suite leaves its plist behind in
        // ~/Library/Preferences after every run, even once emptied. This one
        // lives in a temporary folder and goes with it.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-clientid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = folder.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        }

        let first = AgentConnection.clientID(in: defaults)
        XCTAssertTrue(AgentConnection.isClientID(first), first)
        XCTAssertEqual(AgentConnection.clientID(in: defaults), first, "per install, not per call")

        // A value that is not an id is replaced rather than sent.
        defaults.set("not an id at all", forKey: AgentConnection.clientIDKey)
        let replaced = AgentConnection.clientID(in: defaults)
        XCTAssertTrue(AgentConnection.isClientID(replaced))
        XCTAssertNotEqual(replaced, "not an id at all")
    }

    func testClientIDShape() {
        XCTAssertTrue(AgentConnection.isClientID("0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(AgentConnection.isClientID(""))
        XCTAssertFalse(AgentConnection.isClientID("0123456789ABCDEF0123456789ABCDEF"))
        XCTAssertFalse(AgentConnection.isClientID("0123456789abcdef0123456789abcde"))
        XCTAssertFalse(AgentConnection.isClientID("0123456789abcdef0123456789abcdefa"))
        XCTAssertFalse(AgentConnection.isClientID("0123456789abcdef0123456789abcdeg"))
    }
}
