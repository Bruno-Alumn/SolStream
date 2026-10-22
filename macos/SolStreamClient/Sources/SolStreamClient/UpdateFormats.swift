import CryptoKit
import Foundation

// The formats the updater reads, each a pure function of its input so the
// tests can hold it to `docs/updates.md` without a network or a bundle. That
// document is the contract with the release pipeline and the Windows updater:
// change it, this file and theirs together.

/// Where releases come from, and what a Mac release is called.
enum UpdateSource {
    /// The one place the owner and repository are written.
    static let repository = "Bruno-Alumn/SolStream"
    static let latestRelease = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    static let bundleIdentifier = "com.solstream.macclient"

    static let sumsName = "SHA256SUMS"
    static let signatureName = "SHA256SUMS.sig"
    static func zipName(for version: String) -> String { "SolStream-\(version)-macOS.zip" }

    /// Anything larger is not an update of this app, whatever it says it is.
    static let maximumAssetBytes: Int64 = 200 * 1024 * 1024
    /// The sums and their signature are a few hundred bytes; a cap well above
    /// that keeps a misbehaving server from filling memory before the
    /// signature has had its say.
    static let maximumSmallAssetBytes: Int64 = 64 * 1024
}

/// A release version, compared numerically part by part: 1.0.10 is newer than
/// 1.0.9, which a string comparison gets backwards.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let parts: [Int]
    /// As written, less any leading `v`: what the asset names are built from.
    let text: String

    /// Nil for anything that is not dotted numbers. A tag like `1.1.0-beta`
    /// is not something the updater can order, so it is not something it
    /// moves to.
    init?(_ string: String) {
        var trimmed = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if trimmed.first == "v" { trimmed = trimmed.dropFirst() }
        // Exactly X.Y.Z with no leading zeros, as VERSION, the release workflow's
        // tag check and the Windows updater all require. Reading tags the same
        // way on both sides means a hand-made tag like v1.1 is refused by both,
        // not installed on one and ignored by the other.
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            // Nine digits at most, so no part can overflow an Int on the way in.
            guard (1...9).contains(piece.count),
                  piece.count == 1 || piece.first != "0",
                  piece.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(piece) else { return nil }
            parts.append(value)
        }
        self.parts = parts
        self.text = String(trimmed)
    }

    var description: String { text }

    static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        a.parts == b.parts
    }

    static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        a.parts.lexicographicallyPrecedes(b.parts)
    }
}

/// What `GET /repos/{owner}/{repo}/releases/latest` says, reduced to what the
/// updater uses.
struct Release: Equatable {
    struct Asset: Equatable {
        let name: String
        /// The API's address for it, which takes a token: how a private
        /// repository's asset is fetched.
        let apiURL: URL
        /// The public address, which does not.
        let downloadURL: URL
        let size: Int64
    }

    let tag: String
    let version: ReleaseVersion
    let assets: [Asset]

    func asset(named name: String) -> Asset? {
        assets.first { $0.name == name }
    }

    enum ParseError: Error, Equatable {
        case malformed
        case unreadableTag(String)
    }

    /// The release, or nil when it is one an updater must ignore: a draft or a
    /// prerelease. `latest` never returns either today, but nothing here
    /// should depend on that staying true.
    static func parse(_ data: Data) throws -> Release? {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw ParseError.malformed
        }
        if payload.draft == true || payload.prerelease == true { return nil }
        guard let version = ReleaseVersion(payload.tagName) else {
            throw ParseError.unreadableTag(payload.tagName)
        }
        // An asset without its name or both addresses cannot be fetched
        // either way, so it is as good as missing -- which is how the caller
        // will describe it, and only if it is one the caller needs.
        let assets = (payload.assets ?? []).compactMap { asset -> Asset? in
            guard let name = asset.name,
                  let api = asset.url.flatMap(URL.init(string:)),
                  let download = asset.browserDownloadURL.flatMap(URL.init(string:)) else { return nil }
            return Asset(name: name, apiURL: api, downloadURL: download, size: asset.size ?? 0)
        }
        return Release(tag: payload.tagName, version: version, assets: assets)
    }

    private struct Payload: Decodable {
        let tagName: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [AssetPayload]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease, assets
        }
    }

    /// Every field optional, so that one odd asset is dropped by the
    /// `compactMap` above rather than failing the whole release.
    private struct AssetPayload: Decodable {
        let name: String?
        let url: String?
        let browserDownloadURL: String?
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name, url, size
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// `SHA256SUMS`: one line per asset, 64 lowercase hex digits, two spaces, the
/// file name, a newline.
///
/// Strict on purpose. The file is only ever written by the release workflow,
/// so anything else in it -- a CR, capital hex, `sha256sum`'s binary-mode
/// asterisk, a name given twice -- means it was not, and a lenient parser is
/// one more way to read a line the signer did not mean.
enum ChecksumList {
    /// Name to lowercase hex digest, or nil when any line is malformed.
    static func parse(_ data: Data) -> [String: String]? {
        guard let text = String(data: data, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()  // what follows the final newline: nothing
        guard !lines.isEmpty else { return nil }

        var sums: [String: String] = [:]
        for line in lines {
            let characters = Array(line.unicodeScalars)
            guard characters.count > 66,
                  characters[..<64].allSatisfy({ isLowerHex($0) }),
                  characters[64] == " ", characters[65] == " " else { return nil }
            let name = String(String.UnicodeScalarView(characters[66...]))
            guard isPlainFileName(name), sums[name] == nil else { return nil }
            sums[name] = String(String.UnicodeScalarView(characters[..<64]))
        }
        return sums
    }

    private static func isLowerHex(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
    }

    /// A bare name: nothing that could point outside the release, no leading
    /// space or asterisk, no control characters.
    private static func isPlainFileName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..",
              let first = name.unicodeScalars.first, first != " ", first != "*" else { return false }
        return !name.unicodeScalars.contains {
            $0 == "/" || $0 == "\\" || $0.properties.generalCategory == .control
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// The signature over `SHA256SUMS`: ECDSA P-256 over SHA-256 of its exact
/// bytes, written as base64 of the raw 64-byte r||s and a newline.
enum UpdateSignature {
    /// Base64 of the 65-byte uncompressed X9.63 point. The private half is
    /// never in the repository; see docs/updates.md before changing this.
    static let productionKey =
        "BAqYL3Fb9yQB0RbUnR8Bat8WVYHsUOM7oNvuiUmmYMxBtiB/g7HGlIBIPXaN+X4LdYuN+xyCt92Vhq9itHoNBOE="

    /// - Parameters:
    ///   - signature: the `.sig` file's bytes, newline and all.
    ///   - sums: `SHA256SUMS`'s bytes, exactly as downloaded.
    static func isValid(signature: Data, for sums: Data, publicKey: String = productionKey) -> Bool {
        guard let point = Data(base64Encoded: publicKey),
              let key = try? P256.Signing.PublicKey(x963Representation: point),
              let text = String(data: signature, encoding: .ascii)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let raw = Data(base64Encoded: text), raw.count == 64,
              let parsed = try? P256.Signing.ECDSASignature(rawRepresentation: raw) else {
            return false
        }
        // Hashes with SHA-256 itself, which is the hash the signer used.
        return key.isValidSignature(parsed, for: sums)
    }
}

/// Which hosts the updater talks to, and what it tells them.
enum UpdateHosts {
    /// GitHub's API and site, and the two hosts it hands release downloads to.
    static let allowed: Set<String> = [
        "github.com", "api.github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]
    /// The only host the token is ever sent to. The storage hosts are given a
    /// pre-signed address instead, and refuse a request that also carries an
    /// Authorization header -- so forwarding it would be a leak that also
    /// broke every private download.
    static let tokenHost = "api.github.com"

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), allowed.contains(host),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return true
    }

    /// The request to follow a redirect with, or nil to stop there.
    ///
    /// Built from the request being redirected rather than trusted as
    /// proposed, so the headers the updater chose -- Accept above all, which
    /// decides whether GitHub sends the file or a description of it -- go
    /// along, and the token goes only where it belongs.
    static func redirect(_ proposed: URLRequest, from original: URLRequest?) -> URLRequest? {
        guard isAllowed(proposed.url) else { return nil }
        var next = proposed
        for (field, value) in original?.allHTTPHeaderFields ?? [:]
        where next.value(forHTTPHeaderField: field) == nil {
            next.setValue(value, forHTTPHeaderField: field)
        }
        if proposed.url?.host?.lowercased() != tokenHost {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }
}
