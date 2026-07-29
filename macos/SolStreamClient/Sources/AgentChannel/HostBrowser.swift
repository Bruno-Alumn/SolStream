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
    /// Signalled by the receive thread as it leaves, so `stop()` can be sure
    /// nothing is inside `recvfrom` before the descriptor is closed.
    private let receiveFinished = DispatchSemaphore(value: 0)
    private var timer: DispatchSourceTimer?
    private var found: [String: DiscoveredHost] = [:]
    /// When each host last answered, on the monotonic clock. Same keys as
    /// `found`, and guarded by the same lock.
    private var lastHeard: [String: UInt64] = [:]
    private let lock = NSLock()
    /// Guarded by `lock`. The receive thread reads it once per iteration and
    /// `stop()` writes it, and the whole of `stop()`'s ability to join depends
    /// on the thread actually seeing the write.
    private var running = false

    /// How long a host may stay on the list without answering.
    ///
    /// Every host answers every ask, so silence means the PC has been shut
    /// down, has left the network, or has had SolStream stopped on it. Five
    /// missed answers rather than one, because a broadcast datagram is entitled
    /// to go missing and a machine flickering off the list and back on again is
    /// worse to pick from than one that lingers a few seconds.
    private static let hostTimeout: UInt64 = 10 * 1_000_000_000

    public var onChange: (([DiscoveredHost]) -> Void)?

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public init() {}

    deinit { stop() }

    public func start() {
        guard !isRunning else { return }
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            Log.error("[browse] no UDP socket: \(String(cString: strerror(errno)))")
            return
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // A quarter of a second, not a whole one. This timeout is the only thing
        // that gets the receive thread back out to look at `running`, and
        // `stop()` waits for that to happen before it closes the socket — so it
        // is also how long closing the host list can stall whoever called
        // `stop()`, which is the main thread.
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))

        lock.lock()
        running = true
        lock.unlock()
        // A `stop()` that timed out leaves its thread to signal later, and that
        // stray signal would satisfy the NEXT stop()'s wait without any thread
        // having left — which is the whole hazard again, one run removed. The
        // drain does not block: it takes whatever is already there and no more.
        while receiveFinished.wait(timeout: .now()) == .success {}
        // The descriptor is handed to the thread by value rather than read from
        // `fd` on every pass. A thread that is slow to retire would otherwise
        // pick up whatever number a later `start()` had put there and read a
        // socket belonging to the next run of discovery.
        let descriptor = fd
        let thread = Thread { [weak self] in self?.receiveLoop(fd: descriptor) }
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

    /// Stop discovery, in an order that cannot hand a live descriptor to
    /// somebody else.
    ///
    /// This used to be `close(fd)` from the main thread while the receive thread
    /// sat in `recvfrom` on that same number — the hazard the media client had,
    /// and it is worse here because the browser is started and stopped every
    /// time the host list opens and closes. A closed descriptor number goes
    /// straight back into the kernel's pool, this process opens sockets
    /// constantly while the picker is up, and the loser of that race does not
    /// get an error: it reads somebody else's socket.
    ///
    /// There is no `shutdown` first, and that is not an oversight. The media
    /// client can wake its thread that way because its socket is `connect`ed;
    /// this one is not — it broadcasts and hears from anyone — and on Darwin
    /// `shutdown` on a socket with no peer returns ENOTCONN and wakes nobody.
    /// What retires the thread here is the receive timeout set in `start()`:
    /// `recvfrom` gives up, the loop re-reads `running` under the lock, and
    /// leaves.
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        lock.unlock()

        timer?.cancel()
        timer = nil

        // Bounded: the receive timeout is 250 ms, so a second is several
        // chances to notice. Leaking one descriptor beats hanging the main
        // thread on a socket that will not wake, and leaking is the safe
        // direction — a number this process never gives back is a number
        // nothing else can be handed.
        var joined = true
        if thread != nil {
            joined = receiveFinished.wait(timeout: .now() + 1.0) == .success
            thread = nil
        }

        // Under the lock, which is what stands between this close and an ask
        // handler that started before `cancel()` and is still inside `sendto`.
        lock.lock()
        if joined, fd >= 0 {
            close(fd)
        }
        fd = -1
        found.removeAll()
        lastHeard.removeAll()
        lock.unlock()

        if !joined {
            Log.error("[browse] the discovery thread did not stop; leaving its socket "
                      + "open rather than handing the number back")
        }
    }

    private func ask() {
        expire()
        // The send goes out under the lock, because `stop()` can be closing this
        // descriptor while this handler is standing here: cancelling a timer
        // does not wait for a handler that has already begun. Sending on a
        // number the kernel has just handed back out is the same hazard as
        // reading from one, and it would put a discovery datagram into whatever
        // socket got the number next.
        lock.lock()
        defer { lock.unlock() }
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

    /// Drop hosts that have stopped answering.
    ///
    /// Without this the list only ever grew. A PC discovered once stayed on it
    /// for as long as the picker was open, however long ago it had been shut
    /// down, and choosing it spent the whole connect timeout reaching an address
    /// with nothing behind it — which reads as SolStream being broken rather
    /// than as the PC being off.
    private func expire() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        // `&-` because these are unsigned and this is a difference: `now` is
        // never the earlier of the two, but a wrapping subtraction cannot trap
        // if that assumption is ever wrong, and the wrong answer it would give
        // is "expire this host", which the next ask undoes.
        let stale = lastHeard.filter { now &- $0.value > Self.hostTimeout }.map(\.key)
        guard !stale.isEmpty else { lock.unlock(); return }
        for address in stale {
            found.removeValue(forKey: address)
            lastHeard.removeValue(forKey: address)
        }
        let snapshot = Array(found.values)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.unlock()
        Log.info("[browse] \(stale.count) host(s) stopped answering; dropping them")
        DispatchQueue.main.async { [weak self] in self?.onChange?(snapshot) }
    }

    private func receiveLoop(fd: Int32) {
        // However this loop leaves, `stop()` is waiting to hear that it has.
        defer { receiveFinished.signal() }
        var buffer = [UInt8](repeating: 0, count: 512)
        while isRunning {
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
            lastHeard[address] = DispatchTime.now().uptimeNanoseconds
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
