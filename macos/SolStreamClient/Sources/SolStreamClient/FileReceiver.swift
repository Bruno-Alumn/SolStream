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
    /// Waiting for the connection to come back, with the rest still queued.
    private var paused = false
    /// Replaced by a new connection's receiver: nothing more is fetched here.
    private var abandoned = false
    /// The receiver that took this one's queue over, for a file that was
    /// still being fetched here when it was replaced.
    private weak var successor: FileReceiver?

    /// How long a dropped connection is waited for before the files queued
    /// over it are given up on: the host keeps an offer for half an hour.
    static let reconnectPatience: TimeInterval = 25 * 60

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

    /// Replaced by `receiver`, a new connection's. To the same PC, the queued
    /// files go with it: the host keeps an offer by number, not by connection,
    /// so any connection to it can fetch them. To another PC they can't be,
    /// so that is said once, and the old host is told to let go if it can
    /// still hear. The file being fetched here ends on its own, and if its
    /// connection went it is handed on too.
    func replaced(by receiver: FileReceiver) {
        guard !abandoned else { return }
        abandoned = true
        let waiting = queue
        queue.removeAll()
        if receiver.agent.hostName == agent.hostName {
            successor = receiver
            for offer in waiting { receiver.receive(offer) }
            return
        }
        for offer in waiting { agent.cancelDownload(id: offer.id) }
        let lost = waiting.map { Self.safeName($0.name) }
        guard !lost.isEmpty else { return }
        onReport?(lost.count == 1
            ? "\(lost[0]) didn't arrive: SolStream connected to another PC. Send it again from "
              + "the first one."
            : "\(lost.count) files didn't arrive: SolStream connected to another PC. Send them "
              + "again from the first one.")
    }

    private func next() {
        guard !abandoned, !paused, current == nil, !queue.isEmpty else { return }
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
        agent.download(id: offer.id, size: offer.size, into: handle) { outcome in
            try? handle.close()
            switch outcome {
            case .done:
                break
            case .lost:
                // From the start again once there is a connection: the host
                // still has the offer, and a part file can't be resumed into.
                try? FileManager.default.removeItem(at: partial)
                self.current = nil
                if self.abandoned {
                    if let successor = self.successor {
                        successor.receive(offer)
                    } else {
                        self.onReport?("\(name) didn't arrive: the connection to the PC was "
                                       + "lost. Send it again.")
                    }
                    return
                }
                self.queue.insert(offer, at: 0)
                return self.waitForConnection(since: Date())
            case .refused(let why):
                try? FileManager.default.removeItem(at: partial)
                return self.done(why.map { "\(name) didn't arrive. \($0)" }
                    ?? "\(name) didn't arrive from the PC. Send it again.")
            case .unwritable:
                try? FileManager.default.removeItem(at: partial)
                return self.done("Couldn't save \(name) in Downloads › SolStream. Check there's "
                                 + "room on this Mac, then send it again.")
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

    /// The connection dropped: nothing is fetched until it is back, rather
    /// than every queued file failing at once over a connection that isn't
    /// there, each with a message of its own. Given up on together, in one
    /// message, if it doesn't come back while the host still has them.
    private func waitForConnection(since: Date) {
        paused = true
        guard !abandoned else { return }
        if agent.isSessionUp {
            paused = false
            return next()
        }
        if Date().timeIntervalSince(since) > Self.reconnectPatience {
            paused = false
            let lost = queue.map { Self.safeName($0.name) }
            queue.removeAll()
            guard !lost.isEmpty else { return }
            onReport?(lost.count == 1
                ? "\(lost[0]) didn't arrive: the connection to the PC was lost. Send it again."
                : "\(lost.count) files didn't arrive: the connection to the PC was lost. Send "
                  + "them again.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.waitForConnection(since: since)
        }
    }

    private func done(_ report: String) {
        current = nil
        onReport?(report)
        next()
    }

    static let partSuffix = ".solstream-part"

    /// Delete the hidden part files in `folder` that nothing is writing: one
    /// written to in the last ten minutes may be another copy of SolStream's
    /// download in progress -- one is written to at least once a minute.
    static func removeLeftoverParts(in folder: URL, now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else {
            return
        }
        for name in names where name.hasPrefix(".") && name.hasSuffix(partSuffix) {
            let url = folder.appendingPathComponent(name)
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate, now.timeIntervalSince(modified) < 10 * 60 {
                continue
            }
            try? FileManager.default.removeItem(at: url)
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
        Log.error("[files] could not move a file from the PC into place: every name was taken")
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
        if units(cleaned) > maxNameUnits {
            // APFS counts a name in UTF-16 units of its decomposed form, at
            // most 255: 251 kanji fit, 128 emoji don't, and 100 Ǖ -- 200
            // bytes -- don't either. Cut to leave room for " 9999".
            let ext = String((cleaned as NSString).pathExtension.prefix(20))
            let room = ext.isEmpty ? maxNameUnits : maxNameUnits - units(ext) - 1
            var stem = prefix((cleaned as NSString).deletingPathExtension, units: room)
            while stem.hasPrefix(".") { stem.removeFirst() }
            if stem.isEmpty { stem = "File from PC" }
            cleaned = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return cleaned
    }

    /// Room in a name for what `uniqueURL` may add, " 9999", under 255.
    static let maxNameUnits = 240

    /// The length APFS holds a name to: UTF-16 units, decomposed.
    static func units(_ text: String) -> Int {
        text.decomposedStringWithCanonicalMapping.utf16.count
    }

    /// The longest start of `text` that is at most `units` long as APFS
    /// counts, cut between characters.
    static func prefix(_ text: String, units limit: Int) -> String {
        var result = ""
        var used = 0
        for character in text {
            let size = units(String(character))
            if used + size > limit { break }
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
