import Foundation
import Darwin
import AgentChannel
import SolStreamLogging

/// Waking a PC that is asleep, from the connect window.
///
/// A sleeping PC's network adapter keeps listening for one thing: a "magic
/// packet", six 0xFF bytes and then its own hardware address sixteen times,
/// sent to the whole network. So SolStream has to know the address before the
/// PC sleeps. It asks the host for it each time it connects (`wakeInfo`) and
/// keeps it per PC, with the broadcast address of the network the PC was on.
///
/// What it cannot do: wake a PC through Tailscale or from another network, as
/// a broadcast never leaves the network it is sent on, and wake a PC whose
/// adapter or BIOS has it turned off. The window says so when a wake is not
/// followed by an answer.
enum WakeOnLAN {
    /// One way to reach the PC's adapter: its hardware address, and the
    /// broadcast address of its network when the host knew it.
    struct Target: Codable, Equatable {
        var mac: String
        var broadcast: String?
    }

    /// The six bytes of "AA:BB:CC:DD:EE:FF" or "aa-bb-…", or nil.
    static func bytes(of mac: String) -> [UInt8]? {
        let parts = mac.split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6 else { return nil }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6, bytes != [0, 0, 0, 0, 0, 0] else { return nil }
        return bytes
    }

    /// Six 0xFF, then the address sixteen times: 102 bytes.
    static func magicPacket(for mac: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        return packet
    }

    // MARK: - Kept per PC

    private static let key = "SolStream.wakeTargets"

    /// The targets kept for `host`, empty if it never said.
    static func targets(for host: String, in defaults: UserDefaults = .standard) -> [Target] {
        guard let data = defaults.data(forKey: key),
              let all = try? JSONDecoder().decode([String: [Target]].self, from: data) else {
            return []
        }
        return all[host.lowercased()] ?? []
    }

    static func setTargets(_ targets: [Target], for host: String,
                           in defaults: UserDefaults = .standard) {
        var all = (defaults.data(forKey: key))
            .flatMap { try? JSONDecoder().decode([String: [Target]].self, from: $0) } ?? [:]
        let valid = targets.filter { bytes(of: $0.mac) != nil }
        if valid.isEmpty {
            all.removeValue(forKey: host.lowercased())
        } else {
            all[host.lowercased()] = valid
        }
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    /// What is known after a PC reports `new`: added to what it said
    /// before, not put in its place. A host lists only the adapters that are
    /// up, so a wired desktop that connected once over Wi-Fi with its cable
    /// out would otherwise lose the one address it can be woken through.
    /// The newer word on an address it repeats wins.
    ///
    /// At most `maxTargets`, newest first: Windows can give Wi-Fi a new random
    /// hardware address every day, and kept for ever, the list -- and the
    /// packets sent for every wake -- grew by one each day, all to addresses
    /// nothing answers to any more.
    static func merged(_ old: [Target], _ new: [Target]) -> [Target] {
        let reported = Set(new.map { $0.mac.uppercased() })
        return Array((new + old.filter { !reported.contains($0.mac.uppercased()) })
            .prefix(maxTargets))
    }

    static let maxTargets = 8

    static func forgetAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    /// Ask a connected host for its adapters, and add them to what is kept
    /// for `host`.
    static func learn(from agent: AgentConnection, host: String) {
        agent.wakeInfo { adapters in
            guard let adapters else { return }  // a host from before wakeInfo
            let reported = adapters.map { Target(mac: $0.mac, broadcast: $0.broadcast) }
            DispatchQueue.main.async {
                let targets = merged(Self.targets(for: host), reported)
                setTargets(targets, for: host)
                if !targets.isEmpty {
                    Log.info("[wake] \(host) can be woken: \(targets.count) adapter"
                             + (targets.count == 1 ? "" : "s"))
                }
            }
        }
    }

    // MARK: - Sending

    /// Where a magic packet goes: everywhere on this network, and the PC's own
    /// network's broadcast when it is a different one this Mac can reach.
    static func destinations(for targets: [Target]) -> [String] {
        var all = ["255.255.255.255"]
        for broadcast in targets.compactMap(\.broadcast) where !all.contains(broadcast) {
            all.append(broadcast)
        }
        return all
    }

    /// Send the magic packet for every target, to every destination, on the
    /// two ports wake-on-LAN listens on. True if any packet left this Mac.
    @discardableResult
    static func wake(_ targets: [Target]) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        var sent = false
        for target in targets {
            guard let mac = bytes(of: target.mac) else { continue }
            let packet = magicPacket(for: mac)
            for destination in destinations(for: [target]) {
                for port: UInt16 in [9, 7] {
                    var address = sockaddr_in()
                    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    address.sin_family = sa_family_t(AF_INET)
                    address.sin_port = port.bigEndian
                    guard inet_pton(AF_INET, destination, &address.sin_addr) == 1 else { continue }
                    let result = packet.withUnsafeBytes { bytes in
                        withUnsafePointer(to: &address) {
                            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                                sendto(fd, bytes.baseAddress, bytes.count, 0, $0,
                                       socklen_t(MemoryLayout<sockaddr_in>.size))
                            }
                        }
                    }
                    if result == packet.count { sent = true }
                }
            }
        }
        Log.info("[wake] magic packet \(sent ? "sent" : "could not be sent") for "
                 + "\(targets.count) adapter\(targets.count == 1 ? "" : "s")")
        return sent
    }
}
