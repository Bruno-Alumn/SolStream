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
    /// Hosts the old stores were searched for and had nothing for, and whether
    /// they had nothing at all. Nothing writes those stores any more, so a
    /// "no" stays true and the keychain is not asked again on every keystroke.
    private static var legacyChecked: Set<String> = []
    private static var legacyAnyChecked = false

    public static func token(for host: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = stored(host) { return known }
        guard let moved = legacyDefault(host) ?? legacyKeychain(host) else { return nil }
        if store(moved, for: host) {
            Log.info("[agent] moved the pairing token for \(host) to SolStream's own store")
        } else {
            Log.info("[agent] the pairing token for \(host) stays where an older build kept it,"
                     + " since SolStream's own store could not be written")
        }
        return moved
    }

    public static func hasToken(for host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if stored(host) != nil { return true }
        if legacyChecked.contains(host) { return false }
        if UserDefaults.standard.string(forKey: legacyPrefix + host) != nil { return true }
        // Attributes only: whether an old keychain item exists is answerable
        // without its contents, so this never puts up a prompt.
        var query = keychainQuery(host)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = keychainLookup(query)
        if status == errSecSuccess { return true }
        // Only a definite "none" is remembered. A locked keychain or a busy
        // security daemon answers with an error that passes, and remembered,
        // it would call a paired host unpaired for the rest of the run.
        if status == errSecItemNotFound { legacyChecked.insert(host) }
        return false
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
        if legacyAnyChecked { return false }
        if UserDefaults.standard.dictionaryRepresentation().keys
            .contains(where: { $0.hasPrefix(legacyPrefix) }) { return true }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        let status = keychainLookup(query)
        if status == errSecSuccess { return true }
        // As in `hasToken`: only a definite "none" is remembered.
        if status == errSecItemNotFound { legacyAnyChecked = true }
        return false
    }

    /// The same PC written two ways: a name's case means nothing, and a
    /// trailing dot is the same name. "PC.local", "pc.local" and "PC.local."
    /// were three PCs to the store -- a token typed once, asked for again.
    public static func sameHost(_ a: String, _ b: String) -> Bool {
        func plain(_ host: String) -> String {
            host.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
        }
        return plain(a) == plain(b)
    }

    /// The token kept for `host` under any way of writing it. Call with
    /// `lock` held.
    private static func stored(_ host: String) -> String? {
        let all = loaded()
        return all[host] ?? all.first { sameHost($0.key, host) }?.value
    }

    public static func set(_ token: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        guard stored(host) != token else { return }
        store(token, for: host)
    }

    // MARK: Which PC each token is for

    /// address -> the PC's name, as its greeting gave it when the token was
    /// proved there. Not secret -- the name is in every discovery answer --
    /// so kept in preferences, beside the token store rather than in it,
    /// where an older build reading the token file would trip over it.
    private static let namesKey = "SolStream.pairedPCNames"
    /// Where they are kept: tests give their own, as they do the token file.
    static var namesDefaults: UserDefaults = runningTests
        ? UserDefaults(suiteName: FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-test-names-\(ProcessInfo.processInfo.processIdentifier)")
            .path) ?? .standard
        : .standard
    private static var defaults: UserDefaults { namesDefaults }

    /// Record that `host` is the PC called `name`.
    public static func setName(_ name: String, for host: String) {
        lock.lock()
        defer { lock.unlock() }
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        guard names[host] != name else { return }
        names[host] = name
        defaults.set(names, forKey: namesKey)
    }

    /// The token proved at a PC called `name` -- any of its addresses that
    /// still holds one -- when they all hold the same one. Nil when none
    /// does, or when two PCs share the name and their tokens differ: a guess
    /// between them would be proving one PC's token to the other.
    public static func token(forPCNamed name: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        let tokens = Set(names
            .filter { $0.value.caseInsensitiveCompare(name) == .orderedSame }
            .compactMap { stored($0.key) })
        return tokens.count == 1 ? tokens.first : nil
    }

    /// Whether `token(forPCNamed:)` would find one.
    public static func hasToken(forPCNamed name: String) -> Bool {
        token(forPCNamed: name) != nil
    }

    /// Call with `lock` held.
    private static func forgetName(for host: String) {
        var names = defaults.dictionary(forKey: namesKey) as? [String: String] ?? [:]
        guard names.keys.contains(where: { sameHost($0, host) }) else { return }
        for key in names.keys where sameHost(key, host) { names[key] = nil }
        defaults.set(names, forKey: namesKey)
    }

    public static func remove(for host: String) {
        lock.lock()
        defer { lock.unlock() }
        forgetName(for: host)
        var current = loaded()
        for key in current.keys where sameHost(key, host) { current[key] = nil }
        save(current)
        UserDefaults.standard.removeObject(forKey: legacyPrefix + host)
        if !runningTests { SecItemDelete(keychainQuery(host) as CFDictionary) }
    }

    /// Forget every host.
    public static func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        namesDefaults.removeObject(forKey: namesKey)
        save([:])
        // The test runner's own preferences, under a test: safe to clear.
        for key in UserDefaults.standard.dictionaryRepresentation().keys
        where key.hasPrefix(legacyPrefix) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        guard !runningTests else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        while SecItemDelete(query as CFDictionary) == errSecSuccess {}
    }

    // MARK: - The file

    /// For tests, so they never read or write the person's real tokens.
    static var directoryOverride: URL? {
        didSet {
            lock.lock()
            tokens = nil
            legacyChecked = []
            legacyAnyChecked = false
            lock.unlock()
        }
    }

    /// Running inside a test that set no `directoryOverride`. Then nothing
    /// here may reach the person's real tokens: a test class that forgot the
    /// override once ran `removeAll()` against them, and the PC had to be
    /// paired again. Such a test gets a store of its own, in a folder of this
    /// process's, and the old keychain items are left alone.
    static var unguardedTest: Bool {
        directoryOverride == nil && runningTests
    }

    /// Inside a test process at all. Then the old keychain items -- the
    /// person's own, whatever folder a test gave the file -- are never read
    /// for their tokens or deleted, and the name records go to a suite of
    /// the process's own unless a test gave one.
    static let runningTests = NSClassFromString("XCTestCase") != nil

    private static let unguardedTestDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("solstream-unguarded-test-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    static var fileURL: URL {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent("pairing-tokens.json")
        }
        if unguardedTest {
            return unguardedTestDirectory.appendingPathComponent("pairing-tokens.json")
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
    ///
    /// - Returns: whether the file was written.
    @discardableResult
    private static func store(_ token: String, for host: String) -> Bool {
        var current = loaded()
        // One entry per PC, however its name was typed.
        for key in current.keys where sameHost(key, host) { current[key] = nil }
        current[host] = token
        // Gone from the old places once the new one has it, so a token is never
        // in two stores that could disagree -- and only then: a write that
        // failed leaves the old copy the only one that outlives this run.
        guard save(current) else { return false }
        UserDefaults.standard.removeObject(forKey: legacyPrefix + host)
        if !runningTests { SecItemDelete(keychainQuery(host) as CFDictionary) }
        return true
    }

    /// Call with `lock` held. Kept in memory for this run even if the write
    /// fails, so a session that just authenticated keeps working.
    ///
    /// - Returns: whether the file was written, every step of it.
    @discardableResult
    private static func save(_ next: [String: String]) -> Bool {
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
            return true
        } catch {
            Log.error("[agent] could not save the pairing tokens: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Where earlier builds kept them

    /// Whether the keychain has an item matching an attributes-only query.
    /// Replaceable so the tests can have it fail the way a locked keychain
    /// does.
    static var keychainLookup: ([String: Any]) -> OSStatus = { query in
        SecItemCopyMatching(query as CFDictionary, nil)
    }

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
        // Not read into a test's store, nor deleted after: the keychain is the
        // person's own whatever folder the test gave the file.
        guard !runningTests else { return nil }
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
