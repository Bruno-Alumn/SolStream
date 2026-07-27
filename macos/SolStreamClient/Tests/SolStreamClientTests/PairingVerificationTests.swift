import XCTest
import CryptoKit
import Security
@testable import StreamConnection

/// Checks that SolStream actually verifies the host during pairing.
///
/// These tests build the proofs the way Sunshine's `nvhttp.cpp` builds them, so
/// they are really asserting that our reading of that file is right. A mistake
/// in the byte order here does not fail loudly against a real host — it fails as
/// "pairing rejected" with no indication which side is wrong — and a mistake in
/// the other direction is worse: it accepts everything, which is exactly the
/// state this code was in before.
final class PairingVerificationTests: XCTestCase {

    /// Stands in for the host: a certificate and the key to sign with.
    private struct FakeHost {
        let certPEM: String
        let privateKey: SecKey
        let certificateSignature: Data
    }

    private func makeHost() throws -> FakeHost {
        let identity = try XCTUnwrap(CertificateFactory.makeIdentity(commonName: "Fake Sunshine"))
        let keyDER = try XCTUnwrap(Self.der(fromPEM: identity.keyPEM))
        let certDER = try XCTUnwrap(Self.der(fromPEM: identity.certPEM))
        let key = try XCTUnwrap(SecKeyCreateWithData(keyDER as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ] as CFDictionary, nil))
        let signature = try XCTUnwrap(ClientIdentity.extractCertificateSignature(certDER))
        return FakeHost(certPEM: identity.certPEM, privateKey: key, certificateSignature: signature)
    }

    /// `pairingsecret` = serverSecret(16) || RSA-SHA256(serverSecret), and the
    /// phase-2 hash = SHA256(clientChallenge || signature(serverCert) || serverSecret).
    private func proofs(host: FakeHost, clientChallenge: Data, serverSecret: Data)
        throws -> (pairingSecret: Data, serverHash: Data) {
        var hashInput = clientChallenge
        hashInput.append(host.certificateSignature)
        hashInput.append(serverSecret)
        let serverHash = Data(SHA256.hash(data: hashInput))

        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(
            SecKeyCreateSignature(host.privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                  serverSecret as CFData, &error) as Data?)
        return (serverSecret + signature, serverHash)
    }

    func testAcceptsAHostThatKnewThePinAndOwnsItsCertificate() throws {
        let host = try makeHost()
        let challenge = Data((0..<16).map { UInt8($0) })
        let secret = Data(repeating: 0xAB, count: 16)
        let (pairingSecret, serverHash) = try proofs(host: host, clientChallenge: challenge,
                                                     serverSecret: secret)

        XCTAssertTrue(StreamConnection.verifyServerProofs(
            pairingSecret: pairingSecret, clientChallenge: challenge,
            serverHash: serverHash, serverCertPEM: host.certPEM))
    }

    /// The impersonation this exists to stop: something answers `/pair` without
    /// knowing the PIN, so its hash is over a different client challenge.
    func testRejectsAHostThatDidNotKnowThePin() throws {
        let host = try makeHost()
        let secret = Data(repeating: 0xAB, count: 16)
        let (pairingSecret, serverHash) = try proofs(host: host,
                                                     clientChallenge: Data(repeating: 0x11, count: 16),
                                                     serverSecret: secret)

        XCTAssertFalse(StreamConnection.verifyServerProofs(
            pairingSecret: pairingSecret,
            clientChallenge: Data(repeating: 0x22, count: 16),  // what we actually sent
            serverHash: serverHash, serverCertPEM: host.certPEM))
    }

    /// A host that replays somebody else's certificate cannot sign for it.
    func testRejectsASignatureFromTheWrongKey() throws {
        let host = try makeHost()
        let impostor = try makeHost()
        let challenge = Data(repeating: 0x33, count: 16)
        let secret = Data(repeating: 0xCD, count: 16)

        // Hash built with the presented certificate, signature made with another
        // key — so only the signature check can catch this.
        var hashInput = challenge
        hashInput.append(host.certificateSignature)
        hashInput.append(secret)
        let serverHash = Data(SHA256.hash(data: hashInput))

        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(
            SecKeyCreateSignature(impostor.privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                  secret as CFData, &error) as Data?)

        XCTAssertFalse(StreamConnection.verifyServerProofs(
            pairingSecret: secret + signature, clientChallenge: challenge,
            serverHash: serverHash, serverCertPEM: host.certPEM))
    }

    /// AES-ECB with no padding decrypts anything into something, so before this
    /// check existed a 48-byte blob of noise completed pairing.
    func testRejectsNoise() throws {
        let host = try makeHost()
        XCTAssertFalse(StreamConnection.verifyServerProofs(
            pairingSecret: Data(repeating: 0x5A, count: 272),
            clientChallenge: Data(repeating: 0x01, count: 16),
            serverHash: Data(repeating: 0x02, count: 32),
            serverCertPEM: host.certPEM))
    }

    /// Sunshine bounds this on its own side ("Client pairing secret too short"),
    /// and slicing 16 bytes off something shorter would trap.
    func testRejectsATruncatedPairingSecret() throws {
        let host = try makeHost()
        XCTAssertFalse(StreamConnection.verifyServerProofs(
            pairingSecret: Data(repeating: 0x5A, count: 16),
            clientChallenge: Data(repeating: 0x01, count: 16),
            serverHash: Data(repeating: 0x02, count: 32),
            serverCertPEM: host.certPEM))
    }

    func testRejectsAnUnparseableCertificate() throws {
        XCTAssertFalse(StreamConnection.verifyServerProofs(
            pairingSecret: Data(repeating: 0x5A, count: 272),
            clientChallenge: Data(repeating: 0x01, count: 16),
            serverHash: Data(repeating: 0x02, count: 32),
            serverCertPEM: "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydA==\n-----END CERTIFICATE-----"))
    }

    private static func der(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return Data(base64Encoded: body)
    }
}
