import Foundation
import Security
import SolStreamLogging

/// The pairing token for each host, in the login keychain.
///
/// The token is the root of the media key schedule, so it does not belong in a
/// preferences plist that backups, sync and `defaults read` all see. Stored as a
/// generic password (service `com.solstream.macclient`, account = host) in the
/// file-based login keychain rather than the data-protection one, because the
/// latter needs an entitlement the unbundled `swift build` executable cannot
/// carry.
///
/// Builds before this kept the token in UserDefaults; the first read of a host
/// moves it across and deletes the old entry once the keychain has it.
///
/// Cached per process, so the connect window can ask "is this host paired?"
/// on every keystroke without a keychain round trip — and so a build whose
/// signature the keychain does not recognise yet asks the user at most once.
/// Never logs a token.
public enum TokenStore {
    static let service = "com.solstream.macclient"
    private static let legacyPrefix = "SolStream.agentToken."

    private static let lock = NSLock()
    /// host -> token, or host -> nil once looked up and found missing.
    private static var cache: [String: String?] = [:]

    public static func token(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[host] { return cached }
        let found = readKeychain(host) ?? migrateLegacy(host)
        cache[host] = .some(found)
        return found
    }

    public static func hasToken(for host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[host] { return cached != nil }
        // Attributes only: whether an item exists is answerable without
        // decrypting it, so this never puts up a keychain prompt.
        var query = baseQuery(host)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        return UserDefaults.standard.string(forKey: legacyPrefix + host) != nil
    }

    public static func set(_ token: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        if case .some(.some(let known)) = cache[host], known == token { return }
        if writeKeychain(token, host) {
            cache[host] = .some(token)
        } else {
            // Kept for this run so the session still works; not written
            // anywhere weaker than the keychain.
            cache[host] = .some(token)
            Log.error("[agent] could not store the pairing token for \(host) in the keychain")
        }
    }

    public static func remove(for host: String) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery(host) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyPrefix + host)
        cache[host] = .some(nil)
    }

    /// Forget every host.
    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        // SecItemDelete removes every match in the file-based keychain; looped
        // anyway in case a keychain version stops at the first.
        while SecItemDelete(query as CFDictionary) == errSecSuccess {}
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(legacyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        cache.removeAll()
    }

    // MARK: - Keychain

    private static func baseQuery(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    private static func readKeychain(_ host: String) -> String? {
        var query = baseQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.error("[agent] keychain read for \(host) failed (\(status))")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ token: String, _ host: String) -> Bool {
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery(host) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else {
            Log.error("[agent] keychain update for \(host) failed (\(update))")
            return false
        }
        var add = baseQuery(host)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SolStream pairing token (\(host))"
        if let access = openAccess("SolStream pairing token (\(host))") {
            add[kSecAttrAccess as String] = access
        }
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            Log.error("[agent] keychain add for \(host) failed (\(status))")
        }
        return status == errSecSuccess
    }

    /// An access list that lets SolStream read the item without asking.
    ///
    /// The default trusts only the exact executable that created the item, and
    /// every ad-hoc build is a new executable as far as the keychain knows, so
    /// each update put up "SolStream wants to use your confidential
    /// information" before it could connect -- an interruption on every
    /// upgrade, for a token that until this month sat in a plain preferences
    /// file. Readable by this user's applications without a prompt, the token
    /// is still encrypted at rest in the login keychain and still out of
    /// backups and `defaults read`, which is what moving it here was for.
    ///
    /// The SecAccess API is deprecated in favour of the data-protection
    /// keychain, which needs an entitlement an ad-hoc or unbundled build
    /// cannot carry. Nil on failure, and the item is then stored with the
    /// default access instead.
    private static func openAccess(_ label: String) -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(label as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        let decrypt = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt)
        for case let acl as SecACL in (decrypt as? [Any]) ?? [] {
            // A nil application list means any application.
            SecACLSetContents(acl, nil, label as CFString, [])
        }
        return access
    }

    /// Move a token stored by an older build into the keychain. The old entry
    /// is deleted only once the keychain holds it.
    private static func migrateLegacy(_ host: String) -> String? {
        let key = legacyPrefix + host
        guard let legacy = UserDefaults.standard.string(forKey: key) else { return nil }
        if writeKeychain(legacy, host) {
            UserDefaults.standard.removeObject(forKey: key)
            Log.info("[agent] moved the pairing token for \(host) into the keychain")
        }
        return legacy
    }
}
