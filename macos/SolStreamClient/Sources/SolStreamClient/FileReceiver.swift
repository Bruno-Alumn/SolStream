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
    /// The file being fetched now, by its saved name.
    private var current: String?
    /// Replaced by a new connection's receiver: nothing more is fetched or said.
    private var abandoned = false

    /// Part files are swept once a run, by the first receiver: one left by a
    /// download cut short by a crash or a power cut is hidden and can be 8 GB.
    private static var swept = false

    init(agent: AgentConnection) {
        self.agent = agent
        if !Self.swept {
            Self.swept = true
            Self.removeLeftoverParts(in: Self.folder)
        }
    }

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SolStream", isDirectory: true)
    }

    func receive(_ offer: Offer) {
        guard !abandoned else { return }
        queue.append(offer)
        next()
    }

    /// The connection these offers came over is gone. Said once, for every
    /// queued file that won't now arrive -- they were dropped without a word
    /// -- and the host is told to let go of them, if it can still hear. The one
    /// being fetched says how it ended for itself.
    func abandon() {
        guard !abandoned else { return }
        abandoned = true
        let lost = queue.map { Self.safeName($0.name) }
        for offer in queue { agent.cancelDownload(id: offer.id) }
        queue.removeAll()
        guard !lost.isEmpty else { return }
        onReport?(lost.count == 1
            ? "\(lost[0]) didn't arrive: the connection to the PC was lost. Send it again."
            : "\(lost.count) files didn't arrive: the connection to the PC was lost. Send them "
              + "again.")
    }

    private func next() {
        guard !abandoned, current == nil, !queue.isEmpty else { return }
        let offer = queue.removeFirst()
        let name = Self.safeName(offer.name)
        current = name
        let folder = Self.folder
        // Each early failure lets go of the offer: otherwise it holds one of
        // the host's sixteen slots for half an hour, and the next Send to Mac
        // is told to wait for files that are not on their way.
        func refuse(_ report: String) {
            agent.cancelDownload(id: offer.id)
            done(report)
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return refuse("Couldn't save \(name): the Downloads folder can't be written to.")
        }
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           !Self.hasRoom(for: offer.size, free: free) {
            return refuse("Couldn't save \(name): there isn't enough room on this Mac. Free up "
                          + "some space and send it again.")
        }
        let partial = folder.appendingPathComponent(".\(UUID().uuidString)\(Self.partSuffix)")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else {
            return refuse("Couldn't save \(name) in Downloads › SolStream.")
        }
        Log.info("[files] receiving \(offer.size) bytes from the PC")
        // Held strongly until the download ends, replaced or not: the part file
        // is this closure's to move or delete either way.
        agent.download(id: offer.id, size: offer.size, into: handle) { ok, why in
            try? handle.close()
            guard ok else {
                try? FileManager.default.removeItem(at: partial)
                return self.done(why.map { "\(name) didn't arrive: \($0)" }
                    ?? "\(name) didn't arrive from the PC. Send it again.")
            }
            guard let destination = Self.move(partial, toName: name, in: folder) else {
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
        current = nil
        onReport?(report)
        next()
    }

    static let partSuffix = ".solstream-part"

    /// Delete the hidden part files in `folder`: a download that had one open
    /// is never in progress when a run begins.
    static func removeLeftoverParts(in folder: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return
        }
        for name in names where name.hasPrefix(".") && name.hasSuffix(partSuffix) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    /// Move `partial` to `name` in `folder`, numbered if taken -- and numbered
    /// again if another download took that name between the check and the
    /// move. Nil when it couldn't be moved at all.
    static func move(_ partial: URL, toName name: String, in folder: URL) -> URL? {
        for _ in 0..<5 {
            let destination = uniqueURL(for: name, in: folder) {
                FileManager.default.fileExists(atPath: $0.path)
            }
            do {
                try FileManager.default.moveItem(at: partial, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                continue
            } catch {
                Log.error("[files] could not move a file from the PC into place: \(error)")
                return nil
            }
        }
        return nil
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
            // Cut by bytes, which is what the file system counts: 150
            // characters of Japanese are 450 bytes, past its 255.
            let ext = String((cleaned as NSString).pathExtension.prefix(20))
            let stem = prefix((cleaned as NSString).deletingPathExtension, bytes: 150)
            cleaned = ext.isEmpty ? stem : "\(stem).\(prefix(ext, bytes: 40))"
        }
        return cleaned
    }

    /// The longest start of `text` that is at most `bytes` in UTF-8, cut
    /// between characters.
    static func prefix(_ text: String, bytes: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = character.utf8.count
            if used + size > bytes { break }
            result.append(character)
            used += size
        }
        return result
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
