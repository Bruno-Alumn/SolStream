import Foundation

/// SolStream logging module — shared across all client targets.
/// Each target declares `dependencies: ["SolStreamLogging"]` in Package.swift.
///
/// Usage: `Log.info("...")` or `Logger.info("...")`

/// Simple structured logger for SolStream macOS client.
public enum Logger {
    public enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    public static func info(_ msg: String,
                            file: String = #file,
                            function: String = #function,
                            line: Int = #line) {
        emit(.info, msg, file, line)
    }

    public static func debug(_ msg: String,
                             file: String = #file,
                             function: String = #function,
                             line: Int = #line) {
        emit(.debug, msg, file, line)
    }

    public static func error(_ msg: String,
                             file: String = #file,
                             function: String = #function,
                             line: Int = #line) {
        emit(.error, msg, file, line)
    }

    public static func warning(_ msg: String,
                               file: String = #file,
                               function: String = #function,
                               line: Int = #line) {
        emit(.warning, msg, file, line)
    }

    /// The file the log is being written to, for a "Reveal Log in Finder" item.
    /// Nil only if the log directory could not be created.
    public static var fileURL: URL? { LogFile.shared.url }

    /// Write anything buffered. Worth calling before the process exits, and
    /// before revealing the file to someone who is about to read it.
    public static func flush() { LogFile.shared.flush() }

    /// Record the app and OS version at the top of a session. What a log is
    /// missing when someone sends it in is almost always this.
    public static func startSession(version: String) {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        LogFile.shared.beginSession("SolStream \(version) — \(os)")
    }

    private static func emit(_ level: Level, _ message: String, _ file: String, _ line: Int) {
        let source = URL(fileURLWithPath: file).lastPathComponent
        LogFile.shared.write(level: level, message: message, source: source, line: line)
    }
}

/// Appends the log to a size-capped file in `~/Library/Logs/SolStream/`.
///
/// Printing to stdout is not enough once the client is a packaged `.app`:
/// launched from Finder it has no terminal, so every diagnostic the client
/// produces goes to a pipe nobody is reading. That is fine right up until
/// somebody's stream is black and the only available question is "what does it
/// say?" — at which point there is nothing to ask for.
///
/// Deliberately plain: one file, one previous file, a size cap, and no
/// dependency on os_log. `log show` needs a working command line and a user who
/// knows the subsystem; a file has a path that can be pasted into a message.
final class LogFile {
    static let shared = LogFile()

    let url: URL?

    /// 4 MB, then roll. Large enough to hold a long session at the current
    /// volume, small enough to attach to an email without thinking about it.
    private let sizeLimit = 4 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.solstream.logfile", qos: .utility)
    private var handle: FileHandle?
    private var bytesWritten = 0
    /// Only worth the syscall when someone is watching: a packaged app has no
    /// terminal on the other end of stdout.
    private let echoToTerminal = isatty(STDOUT_FILENO) != 0
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/SolStream", isDirectory: true)
        guard let logs else {
            url = nil
            return
        }
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("SolStream.log")
        open()
    }

    func write(level: Logger.Level, message: String, source: String, line: Int) {
        let stamp = formatter.string(from: Date())
        let text = "[\(stamp)] [\(level.rawValue)] [\(source):\(line)] \(message)\n"
        if echoToTerminal {
            FileHandle.standardOutput.write(Data(text.utf8))
        }
        queue.async { [self] in append(text) }
    }

    func beginSession(_ description: String) {
        let separator = String(repeating: "─", count: 60)
        queue.async { [self] in
            append("\n\(separator)\n\(description)\n\(separator)\n")
        }
    }

    func flush() {
        queue.sync {
            try? handle?.synchronize()
        }
    }

    // MARK: - Private, all on `queue`

    private func open() {
        guard let url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        bytesWritten = (try? handle?.seekToEnd()).flatMap { Int($0) } ?? 0
    }

    private func append(_ text: String) {
        guard let handle else { return }
        let data = Data(text.utf8)
        try? handle.write(contentsOf: data)
        bytesWritten += data.count
        if bytesWritten >= sizeLimit {
            rotate()
        }
    }

    /// Keep exactly one previous file. Two is enough to survive a restart
    /// between "it broke" and "send me the log", and unbounded history in a
    /// directory nobody prunes is how a diagnostic aid becomes a disk problem.
    private func rotate() {
        guard let url else { return }
        try? handle?.close()
        handle = nil

        let previous = url.deletingLastPathComponent()
            .appendingPathComponent("SolStream-previous.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)

        bytesWritten = 0
        open()
    }
}

/// Shorthand for Logger (used by streaming modules).
public typealias Log = Logger
