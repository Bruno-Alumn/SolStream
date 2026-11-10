import AppKit
import CoreServices
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import DesignSystem
import SolStreamLogging

/// A small Mac application for one Windows one, so it can sit in the Dock and
/// be found by Spotlight and Launchpad like anything installed on the Mac.
///
/// The launcher holds no code of SolStream's. It is a folder with a shell
/// script, an icon and a link file (`AppLink`), and all the script does is
/// hand that file to SolStream, which opens the application through the same
/// picker path a click would. Nothing in it needs signing -- a script is not
/// a binary, and a file written on this Mac carries no quarantine -- so it
/// keeps working across SolStream's updates, which replace SolStream and not
/// this.
///
/// A file rather than a URL scheme on purpose. A web page can open any
/// registered URL, and SolStream acting on one would let a page point it at a
/// PC of the page's choosing; only something already on this Mac can hand
/// SolStream a file.
///
/// They live in `~/Applications/SolStream Apps`, beside Chrome's own
/// `Chrome Apps`, where Spotlight and Launchpad look and the user can see
/// them. Removing one from the Dock leaves it there; deleting the folder
/// removes them all.
enum AppLauncher {
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/SolStream Apps", isDirectory: true)
    }

    static let linkFileName = "App." + AppLink.fileExtension

    // MARK: - Making one

    /// Write the launcher for `link`, replacing one already there, and return
    /// where it is.
    ///
    /// Named "<app> (PC)", so it is not taken for the Mac's own Calculator in
    /// Spotlight. A launcher of that name for the same application on another
    /// PC is left alone, and this one is named after its PC instead.
    ///
    /// - Parameter opener: the bundle identifier of the SolStream to hand the
    ///   link to: this one, so a development build makes launchers for itself.
    static func make(_ link: AppLink, icon: CGImage?, opener: String,
                     in folder: URL = folder) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let bundle = destination(for: link, in: folder)
        // Built beside the destination and swapped in whole: a launcher
        // pinned in the Dock keeps its path, and a half-written one would be
        // there for a moment otherwise.
        let staging = folder.appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let name = bundle.deletingPathExtension().lastPathComponent
        let plist = infoPlist(name: name, identifier: identifier(for: link, opener: opener))
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))

        let script = macOS.appendingPathComponent("launch")
        try Data(self.script(for: link, opener: opener).utf8).write(to: script)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        try link.encoded().write(to: resources.appendingPathComponent(linkFileName))
        if let art = Self.icon(from: icon, badge: Self.badge(), name: link.name) {
            try writeICNS(art, to: resources.appendingPathComponent("AppIcon.icns"))
        }

        if fileManager.fileExists(atPath: bundle.path) {
            _ = try fileManager.replaceItemAt(bundle, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: bundle)
        }
        // So Spotlight, Launchpad and the Dock see the new icon now rather
        // than whenever Launch Services next looks.
        LSRegisterURL(bundle as CFURL, true)
        Log.info("[launcher] wrote \(bundle.lastPathComponent) for \"\(link.name)\"")
        return bundle
    }

    /// Where `link`'s launcher goes: the one already made for this app on
    /// this PC if there is one, else the first free of "<app> (PC)",
    /// "<app> (<host>)", "<app> (PC 2)" and on. Never another app's: two Start
    /// Menu apps of one name, or of names that clean up the same, had one
    /// launcher between them, and the Dock icon of the first opened the second.
    static func destination(for link: AppLink, in folder: URL) -> URL {
        // Its own wherever it is, under any name: an app the PC renamed keeps
        // the path its launcher hashes, and a second launcher under the new
        // name shared the first one's bundle id -- two in Spotlight, and
        // Launch Services choosing between them.
        // Not hidden ones: `make` stages a launcher as ".<uuid>.app", and one
        // a crash left behind -- link written, never swapped in -- would be
        // found first and the launcher made where nobody can see it.
        let existing = ((try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let own = existing.first(where: { Self.link(inLauncher: $0)?.sameApp(as: link) == true }) {
            // Under the folder as the caller named it: a listing gives the
            // resolved path (/private/var for /var), another spelling of the
            // same place, which compared as a different launcher.
            return folder.appendingPathComponent(own.lastPathComponent, isDirectory: true)
        }
        let base = fileName(link.name)
        var candidates = ["\(base) (PC)", "\(base) (\(fileName(link.host)))"]
        candidates += (2...20).map { "\(base) (PC \($0))" }
        // And never another app's, even with every one of those taken: a name
        // of its own from what makes it unique.
        candidates.append("\(base) (\(identifier(for: link, opener: "x").suffix(6)))")
        let urls = candidates.map { folder.appendingPathComponent("\($0).app", isDirectory: true) }
        return urls.first { !FileManager.default.fileExists(atPath: $0.path) } ?? urls[urls.count - 1]
    }

    /// The link a launcher at `url` carries, if it is one of ours.
    static func link(inLauncher url: URL) -> AppLink? {
        let file = url.appendingPathComponent("Contents/Resources/\(linkFileName)")
        return (try? Data(contentsOf: file)).flatMap(AppLink.decode)
    }

    /// A name Finder takes: no slash, no colon, nothing hidden, not endless.
    ///
    /// Nothing that disguises a name either -- a right-to-left override would
    /// make one app's launcher read as another's; controlCharacters takes
    /// those too, and the format filter says so -- and cut by what the file
    /// system counts, not by characters: 60 emoji are 240 bytes, past APFS's
    /// 255 once " (PC 20).app" is added.
    static func fileName(_ name: String) -> String {
        var cleaned = String(String.UnicodeScalarView(
            name.replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
                .unicodeScalars.filter {
                    !CharacterSet.controlCharacters.contains($0)
                        && $0.properties.generalCategory != .format
                }))
            .trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        var cut = ""
        for character in cleaned {
            if cut.utf8.count + character.utf8.count > 120 { break }
            cut.append(character)
        }
        cleaned = cut.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "App" : cleaned
    }

    /// Remove every launcher this app made, for Forget Paired PCs: each
    /// would only ask for a token now. Returns the ones removed, whose Dock
    /// tiles `removeFromDock` then takes off.
    @discardableResult
    static func removeAll(in folder: URL = AppLauncher.folder) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil)) ?? []
        var removed: [URL] = []
        for item in items where item.pathExtension == "app" && link(inLauncher: item) != nil {
            if (try? FileManager.default.removeItem(at: item)) != nil { removed.append(item) }
        }
        return removed
    }

    /// Unique per application and PC, and the same every time it is made, so
    /// Launch Services treats a remade launcher as the one it already knew.
    static func identifier(for link: AppLink, opener: String) -> String {
        let key = link.host.lowercased() + "\n" + (link.path ?? link.name).lowercased()
        let digest = SHA256.hash(data: Data(key.utf8))
        return opener + ".app." + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func infoPlist(name: String, identifier: String) -> [String: Any] {
        [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            // Hands the file over and exits: no Dock icon of its own bouncing
            // beside SolStream's while it does.
            "LSUIElement": true,
        ]
    }

    /// The whole of a launcher's behaviour. The bundle identifier rather than
    /// a path, so SolStream can be moved or updated without breaking it.
    static func script(for link: AppLink, opener: String) -> String {
        """
        #!/bin/sh
        # Opens \(link.name.replacingOccurrences(of: "\n", with: " ")) on the PC, in SolStream.
        exec /usr/bin/open -b \(shellQuoted(opener)) "$(dirname "$0")/../Resources/\(linkFileName)"

        """
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - The Dock

    /// Pin `launcher` at the end of the Dock's applications, unless it is
    /// there already. False when the Dock's settings could not be read or
    /// written -- a managed Mac, say -- and the caller shows it in Finder
    /// instead, to be dragged there by hand.
    ///
    /// There is no API for this. The Dock keeps its tiles in its preferences
    /// and reads them when it starts, so the tile is added there and the Dock
    /// restarted: it disappears for a moment and comes back with the tile.
    static func addToDock(_ launcher: URL) -> Bool {
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let tiles = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else {
            Log.error("[launcher] could not read the Dock's applications")
            return false
        }
        let url = URL(fileURLWithPath: launcher.path, isDirectory: true).absoluteString
        if tiles.contains(where: { Self.url(ofTile: $0) == url }) {
            Log.info("[launcher] \(launcher.lastPathComponent) is in the Dock already")
            return true
        }
        let tile: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": launcher.deletingPathExtension().lastPathComponent,
                "file-data": ["_CFURLString": url, "_CFURLStringType": 15],
            ] as [String: Any],
        ]
        CFPreferencesSetAppValue(key, (tiles + [tile]) as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            Log.error("[launcher] could not save the Dock's applications")
            return false
        }
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        do {
            try restart.run()
        } catch {
            Log.error("[launcher] could not restart the Dock: \(error)")
            return false
        }
        Log.info("[launcher] added \(launcher.lastPathComponent) to the Dock")
        return true
    }

    /// Take the tiles of launchers just removed off the Dock. Left there,
    /// each was a question mark that did nothing, straight after the person
    /// had asked for the launchers to go. Only the Dock's own tiles for
    /// those exact bundles; restarted only when one was taken off.
    @discardableResult
    static func removeFromDock(_ launchers: [URL]) -> Bool {
        guard !launchers.isEmpty else { return true }
        let domain = "com.apple.dock" as CFString
        let key = "persistent-apps" as CFString
        guard let tiles = CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] else {
            Log.error("[launcher] could not read the Dock's applications")
            return false
        }
        let kept = Self.tiles(tiles, without: launchers)
        guard kept.count != tiles.count else { return true }
        CFPreferencesSetAppValue(key, kept as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            Log.error("[launcher] could not save the Dock's applications")
            return false
        }
        let restart = Process()
        restart.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        restart.arguments = ["Dock"]
        do {
            try restart.run()
        } catch {
            Log.error("[launcher] could not restart the Dock: \(error)")
            return false
        }
        Log.info("[launcher] took \(tiles.count - kept.count) launcher tile(s) off the Dock")
        return true
    }

    /// `tiles` without those of `launchers`, matched by the URL the Dock
    /// keeps, as `addToDock` writes it.
    static func tiles(_ tiles: [[String: Any]], without launchers: [URL]) -> [[String: Any]] {
        let gone = Set(launchers.map {
            URL(fileURLWithPath: $0.path, isDirectory: true).absoluteString
        })
        return tiles.filter { Self.url(ofTile: $0).map { !gone.contains($0) } ?? true }
    }

    static func url(ofTile tile: [String: Any]) -> String? {
        let data = tile["tile-data"] as? [String: Any]
        return (data?["file-data"] as? [String: Any])?["_CFURLString"] as? String
    }

    // MARK: - The icon

    /// SolStream's own icon, for the corner of every launcher's.
    private static func badge() -> CGImage? {
        var rect = NSRect(x: 0, y: 0, width: 512, height: 512)
        return NSApp?.applicationIconImage?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// The Windows application's icon on a light tile of the Mac's own shape,
    /// with SolStream's in the corner to say where it runs.
    ///
    /// On a tile because Windows icons are drawn to stand alone on a desktop
    /// of any colour, and a bare one sits oddly among the Dock's squares --
    /// recent macOS puts such an icon on a grey plate of its own anyway. The
    /// tile is Apple's grid, 824 of 1,024 with a soft shadow, the same as
    /// SolStream's (`assets/logo`), so it sits at the size of its neighbours.
    /// Hosts send 64 pixels, or 256 when asked and able, often with empty
    /// margins; the margins are trimmed so a small icon is not drawn smaller.
    /// With no icon at all -- some shortcuts have none Windows will give up --
    /// the app's initials, as its row in the picker shows.
    static func icon(from windowsIcon: CGImage?, badge: CGImage?, name: String) -> CGImage? {
        let side = 1024
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24,
                          color: CGColor(gray: 0, alpha: 0.28))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(shape)
        context.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                  colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                                           CGColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY),
                                   end: CGPoint(x: 0, y: tile.minY), options: [])
        context.restoreGState()

        if let art = windowsIcon.flatMap(trimmed) {
            let box: CGFloat = 520
            let scale = box / CGFloat(max(art.width, art.height))
            let size = CGSize(width: CGFloat(art.width) * scale, height: CGFloat(art.height) * scale)
            context.draw(art, in: CGRect(x: (CGFloat(side) - size.width) / 2,
                                         y: (CGFloat(side) - size.height) / 2 + 20,
                                         width: size.width, height: size.height))
        } else {
            let initials = DS.Monogram.initials(from: name)
            let text = NSAttributedString(string: initials, attributes: [
                .font: NSFont.systemFont(ofSize: 300, weight: .semibold),
                .foregroundColor: NSColor(srgbRed: 0.27, green: 0.31, blue: 0.38, alpha: 1),
            ])
            let size = text.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            text.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2,
                                  y: (CGFloat(side) - size.height) / 2 + 20))
            NSGraphicsContext.restoreGraphicsState()
        }

        if let badge {
            // Its own icon carries Apple's margins, so the drawn square is
            // bigger than the tile it shows.
            context.draw(badge, in: CGRect(x: 640, y: 56, width: 340, height: 340))
        }
        return context.makeImage()
    }

    /// `image` without the fully transparent rows and columns around it.
    static func trimmed(_ image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // Drawn inside the closure: `&pixels` passed straight to CGContext is
        // a pointer good only for that one call, and the context keeps it.
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return image }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // A square, so the icon's own proportions survive the fit.
        let side = max(maxX - minX + 1, maxY - minY + 1)
        let midX = (minX + maxX + 1) / 2, midY = (minY + maxY + 1) / 2
        let rect = CGRect(x: midX - side / 2, y: midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        return image.cropping(to: rect) ?? image
    }

    /// Every size the Dock, Finder and Spotlight ask for, from 16 to 1,024.
    static func writeICNS(_ image: CGImage, to url: URL) throws {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for size in sizes {
            guard let scaled = scaled(image, to: size) else { continue }
            CGImageDestinationAddImage(destination, scaled, nil)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Halved step by step down to the size, which keeps fine lines from
    /// going ragged the way one big reduction does.
    private static func scaled(_ image: CGImage, to size: Int) -> CGImage? {
        var current = image
        while current.width / 2 >= size {
            guard let half = draw(current, side: current.width / 2) else { return nil }
            current = half
        }
        return current.width == size ? current : draw(current, side: size)
    }

    private static func draw(_ image: CGImage, side: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
