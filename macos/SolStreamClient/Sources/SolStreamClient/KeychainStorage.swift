import Foundation
import Security

/// Stores and retrieves SolStream pairing credentials in the macOS Keychain.
///
/// Uses kSecClassGenericPassword with the service name "SolStream"
/// and an account name matching the server host address.
///
/// Thread safety: all methods are thread-safe (Keychain API is atomic).
public enum KeychainStorage {

    /// Store a session token and server fingerprint for a given host.
    /// @return True if the credentials were stored successfully.
    @discardableResult
    public static func store(host: String,
                             token: Data,
                             serverFingerprint: Data) -> Bool
    {
        // Build the credential blob: 4-byte token length + token + fingerprint
        var blob = Data()
        withUnsafeBytes(of: UInt32(token.count).bigEndian) { blob.append($0) }
        blob.append(token)
        blob.append(serverFingerprint)

        // Remove old entry first.
        delete(host: host)

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "SolStream" as CFString,
            kSecAttrAccount: host as CFString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData: blob as CFData,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve stored credentials for a host.
    /// @return (token, serverFingerprint) or nil if not found.
    public static func retrieve(host: String) -> (token: Data, serverFingerprint: Data)? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "SolStream" as CFString,
            kSecAttrAccount: host as CFString,
            kSecReturnData: true as CFBoolean,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }

        // Parse: 4-byte length + token + fingerprint
        guard data.count >= 4 else { return nil }

        let tokenLength = Int(CFSwapInt32BigToHost(
            data.withUnsafeBytes { $0.load(as: UInt32.self) }))

        guard data.count >= 4 + tokenLength + 32 else { return nil }

        let token = data.subdata(in: 4..<(4 + tokenLength))
        let fingerprint = data.subdata(in: (4 + tokenLength)..<(4 + tokenLength + 32))

        return (token, fingerprint)
    }

    /// Delete stored credentials for a host.
    @discardableResult
    public static func delete(host: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "SolStream" as CFString,
            kSecAttrAccount: host as CFString,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if credentials exist for a host.
    public static func exists(host: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "SolStream" as CFString,
            kSecAttrAccount: host as CFString,
            kSecReturnData: false as CFBoolean,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Remove all SolStream credentials (on re-pair or reset).
    public static func clearAll() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: "SolStream" as CFString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
