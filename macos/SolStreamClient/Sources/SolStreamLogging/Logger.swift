import Foundation

/// SolStream logging module — shared across all client targets.
/// Each target declares `dependencies: ["SolStreamLogging"]` in Package.swift.
///
/// Usage: `Log.info("...")` or `Logger.info("...")`

/// Simple structured logger for SolStream macOS client.
public enum Logger {
    public static func info(_ msg: String,
                     file: String = #file,
                     function: String = #function,
                     line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [INFO] [\(sourceFile(file)):\(line)] \(msg)")
        fflush(stdout)
    }

    public static func debug(_ msg: String,
                      file: String = #file,
                      function: String = #function,
                      line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [DEBUG] [\(sourceFile(file)):\(line)] \(msg)")
        fflush(stdout)
    }

    public static func error(_ msg: String,
                      file: String = #file,
                      function: String = #function,
                      line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [ERROR] [\(sourceFile(file)):\(line)] \(msg)")
        fflush(stderr)
    }

    public static func warning(_ msg: String,
                        file: String = #file,
                        function: String = #function,
                        line: Int = #line) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] [WARN] [\(sourceFile(file)):\(line)] \(msg)")
        fflush(stdout)
    }

    private static func sourceFile(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Shorthand for Logger (used by streaming modules).
public typealias Log = Logger
