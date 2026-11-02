import AppKit
import AgentChannel
import SolStreamLogging

/// Files sent from the PC with Send to Mac, saved in ~/Downloads/SolStream.
///
/// One at a time, in the order offered: a dozen files sent at once would
/// otherwise interleave their chunks on the one connection the windows also
/// use. Each is written beside its final name and moved there only once every
/// byte has come, so a half-sent file never looks whole; a name already taken
/// gets a number, so nothing on the Mac is ever overwritten.
/// Used on the main queue only, where every answer from `download` arrives.
final class FileReceiver {
    struct Offer {
        let id: UInt64
        let name: String
        let size: Int64
    }

    /// What to tell the person: a file arrived, or why it didn't.
    var onReport: ((String) -> Void)?

    let agent: AgentConnection
    private var queue: [Offer] = []
    private var busy = false

    init(agent: AgentConnection) {
        self.agent = agent
    }

    func receive(_ offer: Offer) {
        queue.append(offer)
        next()
    }

    private func next() {
        guard !busy, !queue.isEmpty else { return }
        let offer = queue.removeFirst()
        busy = true
        let name = Self.safeName(offer.name)
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SolStream", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return done("Couldn't save \(name): the Downloads folder can't be written to.")
        }
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           !Self.hasRoom(for: offer.size, free: free) {
            return done("Couldn't save \(name): there isn't enough room on this Mac. Free up "
                        + "some space and send it again.")
        }
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).solstream-part")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else {
            return done("Couldn't save \(name) in Downloads › SolStream.")
        }
        Log.info("[files] receiving \(offer.size) bytes from the PC")
        agent.download(id: offer.id, size: offer.size, into: handle) { [weak self] ok in
            try? handle.close()
            // Before anything else: this receiver may have been replaced by a
            // new connection's, and a part file must not outlive its download.
            if !ok {
                try? FileManager.default.removeItem(at: partial)
            }
            guard let self else { return }
            guard ok else {
                return self.done("\(name) didn't arrive from the PC. Send it again.")
            }
            let destination = Self.uniqueURL(for: name, in: folder) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            do {
                try FileManager.default.moveItem(at: partial, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                return self.done("Couldn't save \(name) in Downloads › SolStream.")
            }
            Self.markDownloaded(destination)
            // The Downloads stack in the Dock bounces, as for any download.
            DistributedNotificationCenter.default().post(
                name: Notification.Name("com.apple.DownloadFileFinished"),
                object: destination.path)
            Log.info("[files] saved a file from the PC")
            self.done("\(destination.lastPathComponent) arrived from the PC. It's in "
                      + "Downloads › SolStream.")
        }
    }

    private func done(_ report: String) {
        onReport?(report)
        busy = false
        next()
    }

    /// Quarantined as a download, as a browser marks one: Gatekeeper checks it
    /// before it runs, which a script or an app from the PC must not skip --
    /// all it takes to offer one is a program running on the PC.
    static func markDownloaded(_ url: URL) {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: "SolStream",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var marked = url
        do {
            try marked.setResourceValues(values)
        } catch {
            Log.error("[files] could not mark a file from the PC as downloaded: \(error)")
        }
    }

    /// Room for `size` bytes with 1 GB left over.
    static func hasRoom(for size: Int64, free: Int64) -> Bool {
        free - size >= 1 << 30
    }

    /// The name a file from the PC is saved under: its last component only,
    /// with nothing that is a path or hides it -- no slashes or colons, no
    /// control characters, no leading dot -- and never empty.
    static func safeName(_ name: String) -> String {
        let last = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var cleaned = String(last.unicodeScalars.map { scalar -> Character in
            if scalar == ":" || CharacterSet.controlCharacters.contains(scalar)
                || scalar.properties.generalCategory == .format {
                return "_"
            }
            return Character(scalar)
        })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty { cleaned = "File from PC" }
        if cleaned.utf8.count > 200 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(150))
            cleaned = ext.isEmpty ? stem : "\(stem).\(ext.prefix(20))"
        }
        return cleaned
    }

    /// `name` in `folder`, or "name 2.ext", "name 3.ext"… when it is taken.
    static func uniqueURL(for name: String, in folder: URL,
                                      exists: (URL) -> Bool) -> URL {
        let first = folder.appendingPathComponent(name)
        guard exists(first) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for number in 2...9999 {
            let candidate = folder.appendingPathComponent(
                ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            if !exists(candidate) { return candidate }
        }
        return folder.appendingPathComponent("\(UUID().uuidString)-\(name)")
    }
}
