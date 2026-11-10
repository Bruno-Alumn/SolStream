import AgentChannel
import Foundation
import SolStreamLogging

/// Forget one PC's pairing, from its row in the PC list. Forget Paired PCs
/// forgot every PC at once, so a Mac paired with two had to pair both again
/// when one was reinstalled or given away.
enum PairingForget {
    /// The addresses the PC at `address`, called `name`, is paired at: that
    /// one, and every other it was paired at under its name -- the router's
    /// next address for it, or its Wi-Fi and Ethernet both.
    static func hosts(address: String, name: String?) -> [String] {
        var hosts = [address]
        for host in name.map(TokenStore.hosts(forPCNamed:)) ?? []
        where !hosts.contains(where: { TokenStore.sameHost($0, host) }) {
            hosts.append(host)
        }
        return hosts
    }

    /// The Dock launchers made for apps on those addresses.
    static func launcherCount(for hosts: [String], in folder: URL = AppLauncher.folder) -> Int {
        AppLauncher.all(in: folder).filter { link in
            hosts.contains { AppLink.sameHost($0, link.host) }
        }.count
    }

    /// Forget the token, how to wake the PC, and what to reopen there; and
    /// its Dock launchers when asked.
    static func forget(hosts: [String], removingLaunchers: Bool,
                       defaults: UserDefaults = .standard) {
        for host in hosts {
            TokenStore.remove(for: host)
            WakeOnLAN.setTargets([], for: host, in: defaults)
        }
        // Kept, the next launch would reconnect to the PC just forgotten, by
        // itself, and ask for its token at once.
        if let last = AppLink.last(in: defaults),
           hosts.contains(where: { AppLink.sameHost($0, last.host) }) {
            AppLink.setLast(nil, in: defaults)
        }
        if removingLaunchers {
            let removed = AppLauncher.remove(forHosts: hosts)
            AppLauncher.removeFromDock(removed)
            Log.info("[launcher] removed \(removed.count) launcher(s) with the pairing")
        }
        NotificationCenter.default.post(name: AppLauncher.didChange, object: nil)
        Log.info("[agent] forgot the pairing for \(hosts.count) address(es) of one PC")
    }
}
