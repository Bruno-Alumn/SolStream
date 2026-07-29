import Foundation
import Darwin
import SolStreamLogging

/// A SolStream host found on the local network.
public struct DiscoveredHost: Sendable, Equatable, Identifiable, Hashable {
    /// The host's computer name, as it reports it.
    public let name: String
    /// The address it answered from. Always known: a host is discovered BY
    /// answering, so there is nothing left to resolve.
    public let address: String?

    public var id: String { name }

    public var connectTarget: String {
        address ?? "\(name).local"
    }
}

/// Finds SolStream hosts, so nobody has to type an IP address.
///
/// This used to browse Bonjour for `_nvstream._tcp`, the record Sunshine
/// advertises and Moonlight looks for. Nothing advertises that any more, so it
/// found nothing — a feature that had quietly stopped working rather than one
/// that had been removed.
///
/// What replaces it is smaller than what it replaces: one UDP datagram to the
/// broadcast address, and a host that answers with its name. No mDNS responder,
/// no service registration, and nothing to install on the Windows side beyond
/// the agent that is already running.
///
/// It reveals a computer name and the fact that SolStream is installed, to
/// anyone already on the same network segment — which a port scan establishes
/// anyway. It carries no token and grants nothing: a discovered host still
/// refuses every command until the Mac proves it holds the pairing token.
///
/// Discovery is a convenience and never a requirement. Broadcast does not cross
/// subnets and does not traverse a VPN like Tailscale, so typing an address
/// stays the way to reach anything that is not on this network.
public final class HostBrowser {

    private static let question = "SOLSTREAM-DISCOVER/1"
    private static let answerPrefix = "SOLSTREAM-HOST/1 "

    private var fd: Int32 = -1
    private var thread: Thread?
    private var timer: DispatchSourceTimer?
    private var found: [String: DiscoveredHost] = [:]
    private let lock = NSLock()
    private var running = false

    public var onChange: (([DiscoveredHost]) -> Void)?

    public var isRunning: Bool { running }

    public init() {}

    deinit { stop() }

    public func start() {
        guard !running else { return }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Log.error("[browse] no UDP socket: \(String(cString: strerror(errno)))")
            return
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        running = true
        let thread = Thread { [weak self] in self?.receiveLoop() }
        thread.name = "solstream.discovery"
        thread.start()
        self.thread = thread

        // Asked repeatedly rather than once: a PC that was asleep, or a Mac that
        // has just joined the network, has to be able to appear without the user
        // reopening the list.
        let source = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "solstream.discovery.ask"))
        source.schedule(deadline: .now(), repeating: .seconds(2))
        source.setEventHandler { [weak self] in self?.ask() }
        source.resume()
        timer = source
        Log.info("[browse] asking for SolStream hosts on the local network")
    }

    public func stop() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        if fd >= 0 {
            close(fd)
            fd = -1
        }
        lock.lock()
        found.removeAll()
        lock.unlock()
    }

    private func ask() {
        guard fd >= 0 else { return }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = StreamPorts.discovery.bigEndian
        target.sin_addr.s_addr = INADDR_BROADCAST
        let payload = Data(Self.question.utf8)
        _ = payload.withUnsafeBytes { raw in
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    sendto(fd, raw.baseAddress, raw.count, 0, address,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 512)
        while running {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                    recvfrom(fd, &buffer, buffer.count, 0, address, &fromLength)
                }
            }
            guard n > 0 else { continue }
            guard let text = String(bytes: buffer[0..<n], encoding: .utf8),
                  text.hasPrefix(Self.answerPrefix) else { continue }

            let name = String(text.dropFirst(Self.answerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count < 64 else { continue }

            var addressText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var raw = from.sin_addr
            guard inet_ntop(AF_INET, &raw, &addressText, socklen_t(INET_ADDRSTRLEN)) != nil,
                  let address = String(validatingUTF8: addressText) else { continue }

            lock.lock()
            let host = DiscoveredHost(name: name, address: address)
            let changed = found[address] != host
            found[address] = host
            let snapshot = Array(found.values)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lock.unlock()
            if changed {
                DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
            }
        }
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
