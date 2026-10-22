import AppKit
import Darwin

/// Whether this Mac can reach a PC that is not on the same network.
///
/// SolStream finds a PC on the home network by itself, and that is where
/// most people first use it. Away from home the same PC is only reachable
/// through something that joins the two machines, and Tailscale is the one
/// that asks nothing of the router and costs nothing for one person. So the
/// connect window recommends it -- quietly, and only when it would help: on
/// a first run, and when the PC on show is not answering.
///
/// The decision is a pure function of two facts -- the addresses on each of
/// this Mac's tunnels, and whether Tailscale is installed -- so it can be
/// tested without either; `current()` is the one place that reads the real
/// ones.
enum TailscaleStatus: Equatable {
    /// On, with this address on the tailnet.
    case connected(address: String)
    /// The app is here, but nothing is on the tailnet: switched off, or
    /// signed out.
    case installedButOff
    case missing

    static let downloadURL = URL(string: "https://tailscale.com/download")!

    /// The App Store build and the standalone one. Both are "Tailscale" in
    /// /Applications, but either can live elsewhere, so the bundle identifier
    /// is asked first.
    static let bundleIdentifiers = ["io.tailscale.ipn.macos", "io.tailscale.ipn.macsys"]

    /// Tailscale with no app: Homebrew's `tailscale` formula, on Apple
    /// silicon and on Intel, or a daemon that is running from wherever it
    /// was put, which leaves its socket here.
    static let commandLinePaths = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                                   "/var/run/tailscaled.socket"]

    // MARK: - The decision

    /// - Parameters:
    ///   - tunnels: the addresses on each tunnel interface, one list per
    ///     interface, IPv4 and IPv6 together.
    ///   - installed: whether Tailscale is on this Mac at all, the app or
    ///     only its command line.
    ///
    /// An address in Tailscale's range is not enough by itself. Other
    /// overlay VPNs hand out the same range on a tunnel of their own --
    /// NetBird 100.64.0.0/10, Cloudflare WARP 100.96.0.0/12 -- and a Mac on
    /// one of them was told it was on Tailscale, so it was never offered
    /// Tailscale, and a Tailscale address that could not answer was blamed
    /// on the PC. Tailscale gives every device an IPv6 address in its own
    /// prefix as well, on the same tunnel, and that prefix is Tailscale's
    /// alone.
    static func decide(tunnels: [[String]], installed: Bool) -> TailscaleStatus {
        for addresses in tunnels where addresses.contains(where: isTailscaleIPv6) {
            if let address = addresses.first(where: isTailscaleAddress) {
                return .connected(address: address)
            }
        }
        // A tailnet can be set to give out no IPv6 addresses, which leaves a
        // tunnel with the range and no IPv6 address of its own beside it --
        // but so does NetBird before 0.71. Taken as Tailscale where Tailscale
        // is installed, which is the likelier of the two there. A tunnel with
        // some other IPv6 address of its own is somebody else's, a unique
        // local one included: NetBird gives each peer one of those by default
        // since 0.71. A Headscale server's prefix has to lie inside
        // Tailscale's, so the loop above has already found it.
        if installed {
            for addresses in tunnels where !addresses.contains(where: isOwnIPv6) {
                if let address = addresses.first(where: isTailscaleAddress) {
                    return .connected(address: address)
                }
            }
        }
        return installed ? .installedButOff : .missing
    }

    /// Tailscale's range, 100.64.0.0/10: the first byte 100 and the top two
    /// bits of the second 01, which is 64 through 127.
    ///
    /// Strict about the form, because the input is an address this Mac
    /// reported and anything else is not one: four decimal parts, each a
    /// byte. `StreamSettings.isRemote(host:)` answers the wider question of
    /// whether a host somebody TYPED is a Tailscale one, names included.
    static func isTailscaleAddress(_ address: String) -> Bool {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var bytes: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII),
                  part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return false }
            bytes.append(value)
        }
        return bytes[0] == 100 && bytes[1] & 0xC0 == 64
    }

    /// Tailscale's IPv6 prefix, fd7a:115c:a1e0::/48: a unique local prefix
    /// of its own, where 100.64.0.0/10 is shared.
    static func isTailscaleIPv6(_ address: String) -> Bool {
        guard let bytes = ipv6Bytes(address) else { return false }
        return bytes.prefix(6).elementsEqual([0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    /// An IPv6 address the tunnel was given, as against the link-local one
    /// (fe80::/10) macOS puts on every tunnel by itself.
    static func isOwnIPv6(_ address: String) -> Bool {
        guard let bytes = ipv6Bytes(address) else { return false }
        return !(bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
    }

    /// The sixteen bytes of an IPv6 address, or nil if it is not one. A
    /// scope -- "%utun4", which link-local addresses are reported with -- is
    /// not part of the address.
    private static func ipv6Bytes(_ address: String) -> [UInt8]? {
        let bare = address.split(separator: "%", maxSplits: 1,
                                 omittingEmptySubsequences: false).first.map(String.init) ?? ""
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, bare, &parsed) == 1 else { return nil }
        return withUnsafeBytes(of: &parsed) { Array($0) }
    }

    // MARK: - What the Mac says

    /// What this Mac is now. Cheap -- one `getifaddrs`, a Launch Services
    /// lookup and a few file checks -- but not free, so the connect window
    /// asks every few seconds at most rather than on every refresh.
    static func current() -> TailscaleStatus {
        decide(tunnels: tunnels(), installed: applicationURL() != nil || hasCommandLine())
    }

    /// The addresses on each of this Mac's tunnel interfaces that are up,
    /// IPv4 and IPv6, one list per interface.
    ///
    /// Tunnels only -- `utun`, which is what Tailscale's network extension
    /// and its command-line daemon both create -- because 100.64.0.0/10 is
    /// not Tailscale's alone: it is the carrier-grade NAT range, and a phone
    /// hotspot hands it out on Wi-Fi. A Mac tethered to one would otherwise
    /// count as on Tailscale and never be told it was not.
    static func tunnels() -> [[String]] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var names: [String] = []
        var found: [String: [String]] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            let name = String(cString: interface.ifa_name)
            guard Int32(interface.ifa_flags) & IFF_UP != 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET)
                      || address.pointee.sa_family == sa_family_t(AF_INET6),
                  name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            if found[name] == nil { names.append(name) }
            found[name, default: []].append(String(cString: host))
        }
        return names.compactMap { found[$0] }
    }

    /// Whether Tailscale's command line is here without the app. Files only,
    /// not `tailscale status`: this is asked on the main thread, and a
    /// process started there would hold up the window.
    static func hasCommandLine(fileExists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> Bool {
        commandLinePaths.contains(where: fileExists)
    }

    /// Where the Tailscale app is, if it is anywhere.
    static func applicationURL() -> URL? {
        for identifier in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                return url
            }
        }
        let usual = URL(fileURLWithPath: "/Applications/Tailscale.app")
        return FileManager.default.fileExists(atPath: usual.path) ? usual : nil
    }

    // MARK: - What the window says

    /// The line and the one thing to do about it, or nil when there is
    /// nothing to say: a Mac already on Tailscale needs no recommending.
    var advice: (words: String, action: String)? {
        switch self {
        case .connected:
            return nil
        case .installedButOff:
            return ("Tailscale is installed but off. Turn it on to reach your PC away from home.",
                    "Open Tailscale")
        case .missing:
            return ("Away from home? Tailscale connects this Mac and your PC from anywhere, free.",
                    "Get Tailscale")
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Do what `advice` offers: open the app, or its download page.
    func act() {
        switch self {
        case .connected:
            return
        case .installedButOff:
            guard let url = Self.applicationURL() else {
                NSWorkspace.shared.open(Self.downloadURL)
                return
            }
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        case .missing:
            NSWorkspace.shared.open(Self.downloadURL)
        }
    }
}
