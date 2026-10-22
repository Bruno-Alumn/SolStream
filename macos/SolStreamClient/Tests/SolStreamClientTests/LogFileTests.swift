import XCTest
import SolStreamLogging

/// A test run logs to the temporary folder, never to the log a person sends
/// in when something goes wrong.
final class LogFileTests: XCTestCase {
    func testATestRunDoesNotWriteTheRealLog() throws {
        let url = try XCTUnwrap(Log.fileURL)
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(url.resolvingSymlinksInPath().path.hasPrefix(temporary), url.path)
        XCTAssertFalse(url.path.contains("/Library/Logs/"), url.path)
    }
}
