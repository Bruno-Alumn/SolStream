import Foundation
import Security
import SolStreamLogging

/// The pairing token for each host, in a file only this user can read.
///
/// The token is the root of the media key schedule, so it does not belong in a
/// preferences plist that sync and `defaults read` see. It lives in
/// `~/Library/Application Support/SolStream/pairing-tokens.json`: the directory
/// 0700, the file 0600, excluded from backups -- the same shape the PC keeps its
/// own copy in, under the user's local application data.
///
/// Not the keychain. It was there briefly, and on current macOS a keychain item
/// is tied by its partition list to the exact signed executable that created
/// it; SolStream is signed ad hoc, so every update is a new executable and
/// every update stopped at "SolStream wants to use your confidential
/// information" before it could connect -- whatever the item's own access list
/// said. A program whose whole point is not to interrupt cannot do that.
///
/// Tokens kept by earlier builds are moved across on first use: from the
/// keychain (read with prompts disabled, so an item macOS will not hand over
/// silently is skipped rather than asked about) and from UserDefaults.
///
/// Cached per process, so the connect window can ask "is this host paired?" on
/// every keystroke without touching the disk. Never logs a token.
public enum TokenStore {
    static let service = "com.solstream.macclient"
    private static let legacyPrefix = "SolStream.agentToken."

    private static let lock = NSLock()
    /// host -> token, as stored. Loaded once.
    private static var tokens: [String: String]?

    public static func token(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = loaded()[host] { return known }
        guard let moved = legacyDefault(host) ?? legacyKeychain(host) else { return nil }
        store(moved, for: host)
        Log.info("[agent] moved the pairing token for \(host) to SolStream's own store")
        return moved
    }

    public static func hasToken(for host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if loaded()[host] != nil { return true }
        if UserDefaults.standard.string(forKey: legacyPrefix + host) != nil { return true }
        // Attributes only: whether an old keychain item exists is answerable
        // without its contents, so this never puts up a prompt.
        var query = keychainQuery(host)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Whether this Mac has paired with any PC at all: what decides whether the
    /// connect window walks somebody through setting one up.
    ///
    /// The file first, from the in-memory copy, which is all a Mac paired by
    /// any recent build has. Only when that is empty are the places earlier
    /// builds kept tokens looked at -- preferences, and the keychain by
    /// attributes alone, so this never puts up a prompt -- because a Mac that
    /// paired years ago and has not connected since is not a new Mac, and
    /// should not be told how to install the PC end it already has.
    public static var hasAnyToken: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !loaded().isEmpty { return true }
        if UserDefaults.standard.dictionaryRepresentation().keys
            .contains(where: { $0.hasPrefix(legacyPrefix) }) { return true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public static func set(_ token: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        guard loaded()[host] != token else { return }
        store(token, for: host)
    }

    public static func remove(for host: String) {
        lock.lock()
        defer { lock.unlock() }
        var current = loaded()
        current[host] = nil
        save(current)
        UserDefaults.standard.removeObject(forKey: legacyPrefix + host)
        SecItemDelete(keychainQuery(host) as CFDictionary)
    }

    /// Forget every host.
    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        save([:])
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(legacyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        while SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }

    // MARK: - The file

    /// For tests, so they never read or write the person's real tokens.
    static var directoryOverride: URL? {
        didSet { lock.lock(); tokens = nil; lock.unlock() }
    }

    static var fileURL: URL {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent("pairing-tokens.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SolStream", isDirectory: true)
            .appendingPathComponent("pairing-tokens.json")
    }

    /// Call with `lock` held.
    private static func loaded() -> [String: String] {
        if let tokens { return tokens }
        var read: [String: String] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            read = decoded
        }
        tokens = read
        return read
    }

    /// Call with `lock` held.
    private static func store(_ token: String, for host: String) {
        var current = loaded()
        current[host] = token
        save(current)
        // Gone from the old places once the new one has it, so a token is never
        // in two stores that could disagree.
        UserDefaults.standard.removeObject(forKey: legacyPrefix + host)
        SecItemDelete(keychainQuery(host) as CFDictionary)
    }

    /// Call with `lock` held. Kept in memory for this run even if the write
    /// fails, so a session that just authenticated keeps working.
    private static func save(_ next: [String: String]) {
        tokens = next
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(next)
            // Written to a 0600 file from the first byte: creating it with the
            // default umask and tightening it afterwards would leave a moment
            // in which it is readable by others.
            let temporary = directory.appendingPathComponent(".pairing-tokens.tmp")
            fm.createFile(atPath: temporary.path, contents: data,
                          attributes: [.posixPermissions: 0o600])
            if fm.fileExists(atPath: fileURL.path) {
                _ = try fm.replaceItemAt(fileURL, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: fileURL)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var url = fileURL
            try url.setResourceValues(excluded)
        } catch {
            Log.error("[agent] could not save the pairing tokens: \(error.localizedDescription)")
        }
    }

    // MARK: - Where earlier builds kept them

    private static func legacyDefault(_ host: String) -> String? {
        UserDefaults.standard.string(forKey: legacyPrefix + host)
    }

    private static func keychainQuery(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    /// A token a keychain build left behind, if macOS hands it over without
    /// asking. Never with a prompt: an item this executable is not trusted for
    /// fails here, and the person types the token once more instead of meeting
    /// a password dialog at launch.
    private static func legacyKeychain(_ host: String) -> String? {
        var query = keychainQuery(host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound {
                Log.info("[agent] an older keychain copy of the token for \(host) "
                         + "could not be read without a prompt (\(status)); skipped")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
