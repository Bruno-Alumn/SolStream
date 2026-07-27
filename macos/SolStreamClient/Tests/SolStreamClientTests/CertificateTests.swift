import XCTest
import Security
@testable import StreamConnection

/// Checks the identity SolStream mints for itself on first launch.
///
/// These are worth having because a malformed certificate does not fail
/// noisily: pairing simply never succeeds, and the interesting error is on the
/// far side of a TLS handshake inside Sunshine. Verifying the DER here means a
/// broken generator is caught by `swift test` rather than by a user who cannot
/// connect.
final class CertificateTests: XCTestCase {

    /// A certificate the Security framework refuses to parse would never get as
    /// far as the wire. `SecCertificateCreateWithData` returns nil on anything
    /// that is not well-formed DER-encoded X.509, which is exactly the check
    /// worth making against a hand-rolled encoder.
    func testGeneratedCertificateParsesAsX509() throws {
        let identity = try XCTUnwrap(CertificateFactory.makeIdentity())
        let der = try XCTUnwrap(Self.der(fromPEM: identity.certPEM))
        XCTAssertNotNil(SecCertificateCreateWithData(nil, der as CFData),
                        "the generated certificate is not parseable X.509")
    }

    /// The certificate has to carry the public half of the key that signs the
    /// pairing challenge. If these ever came from different key pairs, pairing
    /// would fail at phase 4 with nothing but a signature mismatch to go on.
    func testPrivateKeyMatchesCertificatePublicKey() throws {
        let identity = try XCTUnwrap(CertificateFactory.makeIdentity())
        let certDER = try XCTUnwrap(Self.der(fromPEM: identity.certPEM))
        let keyDER = try XCTUnwrap(Self.der(fromPEM: identity.keyPEM))

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, certDER as CFData))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let privateKey = try XCTUnwrap(SecKeyCreateWithData(keyDER as CFData, [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ] as CFDictionary, nil), "the generated key is not loadable PKCS#1")

        let challenge = Data("solstream pairing challenge".utf8)
        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(
            SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                  challenge as CFData, &error) as Data?)
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                            challenge as CFData, signature as CFData, &error),
                      "the certificate does not carry the matching public key")
    }

    /// Pairing phase 3 hashes the certificate's `signatureValue`. The walk that
    /// extracts it has to cope with the certificate this generator produces, not
    /// just the one that used to be embedded.
    func testSignatureIsExtractableForPairing() throws {
        let identity = try XCTUnwrap(CertificateFactory.makeIdentity())
        let der = try XCTUnwrap(Self.der(fromPEM: identity.certPEM))
        let signature = try XCTUnwrap(ClientIdentity.extractCertificateSignature(der))
        // RSA-2048 signs to exactly 256 bytes; a short read here means the DER
        // walk stopped early and silently returned some other element.
        XCTAssertEqual(signature.count, 256)
    }

    /// The certificate must verify against itself.
    ///
    /// This is the check that matters most and the one nothing else here makes:
    /// parsing proves the bytes are shaped like a certificate, but Sunshine
    /// installs the client certificate into an `X509_STORE` as a trust anchor,
    /// and OpenSSL validates an anchor's own signature. If the bytes fed to the
    /// signer ever drifted from the bytes emitted as `tbsCertificate` — an easy
    /// mistake with a hand-rolled encoder, and an invisible one — everything
    /// above would still pass and pairing would still fail.
    func testCertificateSelfSignatureVerifies() throws {
        let identity = try XCTUnwrap(CertificateFactory.makeIdentity())
        let der = try XCTUnwrap(Self.der(fromPEM: identity.certPEM))

        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let publicKey = try XCTUnwrap(SecCertificateCopyKey(certificate))
        let tbs = try XCTUnwrap(Self.tbsCertificate(der))
        let signature = try XCTUnwrap(ClientIdentity.extractCertificateSignature(der))

        var error: Unmanaged<CFError>?
        XCTAssertTrue(SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                            tbs as CFData, signature as CFData, &error),
                      "the certificate does not verify against its own key")

        // Leaves a copy on disk for an independent `openssl verify`, so the
        // encoder is not only ever checked by the framework that wrote it.
        if let dump = ProcessInfo.processInfo.environment["SOLSTREAM_CERT_DUMP"] {
            try? identity.certPEM.write(toFile: dump, atomically: true, encoding: .utf8)
        }
    }

    /// Two installations must not end up with the same identity — the whole
    /// point of generating one per install.
    func testEachIdentityIsDistinct() throws {
        let first = try XCTUnwrap(CertificateFactory.makeIdentity())
        let second = try XCTUnwrap(CertificateFactory.makeIdentity())
        XCTAssertNotEqual(first.certPEM, second.certPEM)
        XCTAssertNotEqual(first.keyPEM, second.keyPEM)
    }

    /// The identity every earlier build shipped must still be recognised, or the
    /// stores already carrying it would never be replaced.
    func testCompromisedSeedIsRecognised() throws {
        XCTAssertTrue(ClientIdentity.isCompromisedSeed(Self.compromisedSeedCertPEM))

        let fresh = try XCTUnwrap(CertificateFactory.makeIdentity())
        XCTAssertFalse(ClientIdentity.isCompromisedSeed(fresh.certPEM))
    }

    // MARK: - Helpers

    /// The `tbsCertificate` element *including* its own tag and length, which is
    /// the exact byte range a certificate signature covers.
    private static func tbsCertificate(_ der: Data) -> Data? {
        var index = der.startIndex
        guard index < der.endIndex, der[index] == 0x30 else { return nil }
        index += 1
        guard let outer = readLength(der, at: index) else { return nil }
        index = outer.next

        let start = index
        guard index < der.endIndex, der[index] == 0x30 else { return nil }
        index += 1
        guard let tbs = readLength(der, at: index) else { return nil }
        let end = tbs.next + tbs.length
        guard end <= der.endIndex else { return nil }
        return Data(der[start..<end])
    }

    private static func readLength(_ der: Data, at index: Data.Index) -> (length: Int, next: Data.Index)? {
        guard index < der.endIndex else { return nil }
        let first = der[index]
        if first & 0x80 == 0 { return (Int(first), index + 1) }
        let count = Int(first & 0x7F)
        guard count > 0, count <= 4, index + 1 + count <= der.endIndex else { return nil }
        var length = 0
        for offset in 1...count {
            length = (length << 8) | Int(der[index + offset])
        }
        return (length, index + 1 + count)
    }

    private static func der(fromPEM pem: String) -> Data? {
        let body = pem.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        return Data(base64Encoded: body)
    }

    /// The retired shared certificate, kept only so the eviction check can be
    /// tested. The private key that went with it is deliberately absent: this
    /// is inert public data, which is why it is safe to keep here and was not
    /// safe to keep in the app.
    private static let compromisedSeedCertPEM = """
    -----BEGIN CERTIFICATE-----
    MIICmjCCAYICCQDmn2B0Q6kHCTANBgkqhkiG9w0BAQsFADAPMQ0wCwYDVQQDDARy
    b3RoMB4XDTI2MDcyMzE1MTI0N1oXDTM2MDcyMDE1MTI0N1owDzENMAsGA1UEAwwE
    cm90aDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAPAdHbaA5WNWnZVN
    oem1fLajG6D+cc66lAIQ61brmmTBCy7Pn6odlOOHDo5Ok9pEpPAqorD2jabjThU6
    FRfeeDBdJVbSgYhNJVnnCdjnU2JmFO8x1TH3JIi0SXVDTLwuPUd7pd7okdRj0e+A
    ETS/HSuovgLQrp4HlfVMgYfi7YAc0XwfMehDfMWHPBQ/UXeFl6iIpSdBclBNlfEv
    nTXtg+9wZ2HFdMx5z4tQ7WOXfmwNxT/9TiSC5nSHE4dk0ciu1oQWUsmNepEIkwCU
    OoPzmlOBPzMvQdtAmTOiLalQ4hLQfzRLXwqE89z/iEGZQqur9A92337n1vZwfGTy
    bytdSecCAwEAATANBgkqhkiG9w0BAQsFAAOCAQEAB3GWzTl6QWihyrgfbbWNhyfQ
    WLYHk4oSkQptiNwvkRw+zSHaeFWp6QC5nIZwh6JAbxpB4zFoXkLwFkY6zs5fVGuO
    nazepLBwe6xwlaJ5uf26MLajNeuBO0h374HTLZzfP5cZQjTops7e+eSkyl6kVAiO
    wA4PGGM144ZiRwdNFnCzj/kJ/8MSBKDx1dsYhALxu490JDlf9z1CAPlMH5lBlMwm
    gOOM2MaA1//tpGsISz8MlrZJfucamYfMX5xtPvzL1aCLguH0iAj6GRLuDgUpcKHs
    38RMQuYMN9mPHz+6uugY1k0xKMs0bnVTdrLB8cv2mwxE4BWMesABgyGF/Ka+BA==
    -----END CERTIFICATE-----
    """
}
