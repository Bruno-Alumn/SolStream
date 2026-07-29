import Foundation
import Network
import SolStreamLogging

/// A Sunshine host found on the local network.
public struct DiscoveredHost: Sendable, Equatable, Identifiable, Hashable {
    /// The advertised instance name, which is the host's computer name.
    public let name: String
    /// Resolved address, once known. Nil while only the name is known.
    public let address: String?

    public var id: String { name }

    /// What to hand to `StreamConnection` — an address if we resolved one, the
    /// `.local` name otherwise, which is resolvable on the same network.
    public var connectTarget: String {
        address ?? "\(name).local"
    }
}

/// Finds Sunshine hosts over mDNS so nobody has to type an IP address.
///
/// Sunshine advertises `_nvstream._tcp` itself — the same record Moonlight
/// browses — so this needs nothing on the host side. Discovery is a convenience
/// and never a requirement: mDNS does not cross subnets, and plenty of networks
/// block multicast outright, so manual entry stays.
public final class HostBrowser {
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private var found: [String: DiscoveredHost] = [:]
    private let queue = DispatchQueue(label: "com.solstream.browse")

    /// Called on the main queue whenever the set of known hosts changes.
    public var onChange: (([DiscoveredHost]) -> Void)?

    /// Whether discovery is still listening. The host list shows a running
    /// footer while it is, so it has to be able to ask.
    public var isRunning: Bool { browser != nil }

    public init() {}

    deinit {
        browser?.cancel()
        resolvers.values.forEach { $0.cancel() }
    }

    public func start() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_nvstream._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                // Not fatal: the connect window still takes a typed address.
                Log.info("[browse] mDNS browse failed: \(error)")
            case .ready:
                Log.info("[browse] looking for Sunshine hosts on the local network")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var names: [String] = []
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                names.append(name)
                if self.found[name] == nil {
                    self.found[name] = DiscoveredHost(name: name, address: nil)
                    self.resolve(result.endpoint, name: name)
                }
            }
            // Drop hosts that have gone away, so a powered-off PC stops being offered.
            for stale in self.found.keys where !names.contains(stale) {
                self.found.removeValue(forKey: stale)
                self.resolvers.removeValue(forKey: stale)?.cancel()
            }
            self.publish()
        }

        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers.removeAll()
    }

    /// Turn a Bonjour endpoint into an address.
    ///
    /// NWBrowser reports service names, not addresses. There is no public resolve
    /// call, so the supported trick is to prepare a connection to the endpoint and
    /// read the resolved path — the connection itself is never used.
    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[name] = connection

        connection.pathUpdateHandler = { [weak self] path in
            guard let self,
                  let remote = path.remoteEndpoint,
                  case .hostPort(let host, _) = remote else { return }

            let address: String?
            switch host {
            case .ipv4(let v4):
                address = "\(v4)".components(separatedBy: "%").first
            case .ipv6(let v6):
                // Skip link-local: it needs a scope id that would not survive
                // being put in a text field.
                address = v6.isLinkLocal ? nil : "\(v6)".components(separatedBy: "%").first
            case .name(let hostname, _):
                address = hostname
            @unknown default:
                address = nil
            }
            guard let address else { return }

            self.queue.async {
                guard self.found[name] != nil else { return }
                self.found[name] = DiscoveredHost(name: name, address: address)
                self.resolvers.removeValue(forKey: name)?.cancel()
                self.publish()
            }
        }
        connection.start(queue: queue)
    }

    private func publish() {
        let hosts = Self.oneRowPerMachine(Array(found.values))
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(hosts)
        }
    }

    /// Collapse the advertisements that are really the same PC.
    ///
    /// A machine running SolStream advertises TWICE: SolStream's own Sunshine
    /// and any Sunshine the user already had both publish `_nvstream._tcp`
    /// under the machine's own hostname, and Bonjour disambiguates the second
    /// as "NAME(1)". The user then sees their PC listed twice, identically, and
    /// picking the wrong one reaches the wrong instance.
    ///
    /// It cannot be fixed on the host: Sunshine advertises unconditionally and
    /// takes the name from the OS rather than from its configuration, and
    /// SolStream ships it unmodified on purpose.
    ///
    /// So it is fixed here, by the only thing that actually identifies a
    /// machine: the address the names resolve to. Entries that have not
    /// resolved yet keep their own row — dropping them would hide a host that
    /// is merely slow to answer.
    static func oneRowPerMachine(_ hosts: [DiscoveredHost]) -> [DiscoveredHost] {
        var byAddress: [String: DiscoveredHost] = [:]
        var unresolved: [DiscoveredHost] = []

        for host in hosts {
            guard let address = host.address else {
                unresolved.append(host)
                continue
            }
            guard let existing = byAddress[address] else {
                byAddress[address] = host
                continue
            }
            // Keep the name Bonjour did not have to rename: "PC" reads as the
            // machine, "PC(1)" reads as a mistake.
            if host.name.count < existing.name.count {
                byAddress[address] = host
            }
        }

        // Names alone have to be enough as well, because resolution is not
        // guaranteed: on the network this was found on, NEITHER advertisement
        // ever resolved to an address — the rows showed their ".local"
        // fallbacks — so an address-only rule collapsed nothing at all.
        //
        // Bonjour's own rename is the signal. It disambiguates a clashing
        // instance by appending "(n)", so "PC(1)" beside "PC" is that machine
        // advertising twice, not a second machine. Only used when the addresses
        // cannot settle it: two rows that DID resolve, to different addresses,
        // are two machines whatever they are called.
        var rows = Array(byAddress.values)
        let resolvedNames = Set(rows.map(\.name))
        for candidate in unresolved
        where !resolvedNames.contains(where: { candidate.name.hasPrefix($0) }) {
            rows.append(candidate)
        }

        let names = Set(rows.map(\.name))
        rows = rows.filter { row in
            guard let base = Self.baseName(of: row.name) else { return true }
            guard let original = rows.first(where: { $0.name == base }) else { return true }
            // Keep both when they resolved to genuinely different machines.
            if let a = row.address, let b = original.address, a != b { return true }
            return false
        }
        _ = names

        return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Which remembered addresses are worth their own row, given what discovery
    /// has already found.
    ///
    /// The connect list draws from two places — hosts found on the network now,
    /// and addresses this Mac has connected to before — and they overlap. Seen
    /// for real: "DESKTOP-EXAMPLE(1)" from discovery listed directly above
    /// "DESKTOP-EXAMPLE.local" from recents, one PC twice, and picking the wrong
    /// one reaches a name that does not resolve. Matching the two address
    /// strings does not catch it, because neither string is the same.
    ///
    /// A machine is recognised by any of the names it can legitimately answer
    /// to: the address discovery would connect to, the address it resolved to,
    /// and its own hostname as a `.local` — including the hostname Bonjour had
    /// to rename, since "PC(1)" is still PC.
    public static func recentsWorthShowing(_ recents: [String],
                                           discovered: [DiscoveredHost]) -> [String] {
        var known: Set<String> = []
        for host in discovered {
            known.insert(host.connectTarget.lowercased())
            if let address = host.address { known.insert(address.lowercased()) }
            known.insert("\(host.name).local".lowercased())
            if let base = baseName(of: host.name) {
                known.insert(base.lowercased())
                known.insert("\(base).local".lowercased())
            }
        }
        return recents.filter { !known.contains($0.lowercased()) }
    }

    /// "DESKTOP-PC(1)" -> "DESKTOP-PC", or nil when the name carries no
    /// Bonjour rename suffix.
    public static func baseName(of name: String) -> String? {
        guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return nil }
        let digits = name[name.index(after: open)..<name.index(before: name.endIndex)]
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        let base = String(name[name.startIndex..<open])
        return base.isEmpty ? nil : base
    }
}
