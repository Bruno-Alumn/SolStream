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
/// The decision is a pure function of two facts -- the addresses this Mac
/// has, and whether the Tailscale app is installed -- so it can be tested
/// without either; `current()` is the one place that reads the real ones.
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

    // MARK: - The decision

    static func decide(addresses: [String], installed: Bool) -> TailscaleStatus {
        if let address = addresses.first(where: isTailscaleAddress) {
            return .connected(address: address)
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

    // MARK: - What the Mac says

    /// What this Mac is now. Cheap -- one `getifaddrs` and a Launch Services
    /// lookup -- but not free, so the connect window asks every few seconds
    /// at most rather than on every refresh.
    static func current() -> TailscaleStatus {
        decide(addresses: tunnelAddresses(), installed: applicationURL() != nil)
    }

    /// The IPv4 addresses on this Mac's tunnel interfaces that are up.
    ///
    /// Tunnels only -- `utun`, which is what Tailscale's network extension
    /// and its command-line daemon both create -- because 100.64.0.0/10 is
    /// not Tailscale's alone: it is the carrier-grade NAT range, and a phone
    /// hotspot hands it out on Wi-Fi. A Mac tethered to one would otherwise
    /// count as on Tailscale and never be told it was not.
    static func tunnelAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard Int32(interface.ifa_flags) & IFF_UP != 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  String(cString: interface.ifa_name).hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            found.append(String(cString: host))
        }
        return found
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
