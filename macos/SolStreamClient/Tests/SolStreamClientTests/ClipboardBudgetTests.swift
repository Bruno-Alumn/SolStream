import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// Checks the clipboard size budget.
///
/// Worth testing because the failure it guards against is not a truncated
/// clipboard: the agent refuses any line past its cap, and until recently
/// dropped the whole client when one arrived — which pulled every streamed
/// window back onto the real desktop mid-session. The numbers on the two sides
/// have to stay in a specific relationship, and nothing else checks that.
final class ClipboardBudgetTests: XCTestCase {

    func testShortTextIsUntouched() {
        let (text, truncated) = AgentConnection.clipboardPayload("hello")
        XCTAssertEqual(text, "hello")
        XCTAssertFalse(truncated)
    }

    func testTextExactlyAtTheLimitIsUntouched() {
        let text = String(repeating: "a", count: AgentConnection.maxClipboardBytes)
        let (result, truncated) = AgentConnection.clipboardPayload(text)
        XCTAssertEqual(result.utf8.count, AgentConnection.maxClipboardBytes)
        XCTAssertFalse(truncated)
    }

    func testAsciiIsTrimmedToTheLimit() {
        let text = String(repeating: "a", count: AgentConnection.maxClipboardBytes + 5_000)
        let (result, truncated) = AgentConnection.clipboardPayload(text)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(result.utf8.count, AgentConnection.maxClipboardBytes)
    }

    /// The case a character count would get wrong. Each of these is three UTF-8
    /// bytes, so a string well inside any character limit is three times over
    /// the byte limit the agent actually enforces.
    func testMultibyteTextIsMeasuredInBytes() {
        let text = String(repeating: "漢", count: AgentConnection.maxClipboardBytes / 2)
        XCTAssertGreaterThan(text.utf8.count, AgentConnection.maxClipboardBytes)

        let (result, truncated) = AgentConnection.clipboardPayload(text)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(result.utf8.count, AgentConnection.maxClipboardBytes)
        // Nothing was cut mid-sequence: re-decoding is lossless, so no
        // replacement characters appeared.
        XCTAssertFalse(result.contains("\u{FFFD}"))
        XCTAssertEqual(String(decoding: Array(result.utf8), as: UTF8.self), result)
    }

    /// A flag emoji is one Character built from two scalars of four bytes each.
    /// Trimming by bytes, or even by scalar, can leave half a flag behind.
    func testGraphemeClustersSurviveTrimming() {
        let text = String(repeating: "🇪🇸", count: AgentConnection.maxClipboardBytes)
        let (result, truncated) = AgentConnection.clipboardPayload(text)
        XCTAssertTrue(truncated)
        XCTAssertLessThanOrEqual(result.utf8.count, AgentConnection.maxClipboardBytes)
        XCTAssertTrue(result.allSatisfy { $0 == "🇪🇸" },
                      "trimming split a grapheme cluster")
    }

    /// The relationship that matters. The agent JSON-escapes the text before it
    /// goes on the wire, and a control byte becomes `\u00xx` — six bytes for
    /// one. If the line cap did not clear six times the payload cap, a clipboard
    /// full of control characters would still tear the channel down.
    func testLineCapClearsTheWorstCaseEscapingOfAFullPayload() {
        XCTAssertGreaterThan(AgentConnection.maxLineBytes,
                             AgentConnection.maxClipboardBytes * 6,
                             "line cap must clear worst-case JSON escaping of a full clipboard")
        XCTAssertGreaterThan(AgentConnection.maxLineBytes,
                             AgentConnection.maxClipboardSetBytes * 6,
                             "line cap must clear worst-case JSON escaping of a full set")
    }

    /// A set is a full payload of the Mac's lines given Windows' CRs, and the
    /// most that can grow is a payload of nothing but line breaks. That still
    /// fits a set whole.
    func testAFullPayloadInWindowsLinesFitsASet() {
        let (payload, _) = AgentConnection.clipboardPayload(
            String(repeating: "\n", count: AgentConnection.maxClipboardBytes + 100))
        let windows = ClipboardBridge.windowsLineEndings(payload)
        XCTAssertEqual(windows.utf8.count, AgentConnection.maxClipboardSetBytes)
        let (sent, truncated) = AgentConnection.clipboardSetPayload(windows)
        XCTAssertFalse(truncated)
        XCTAssertEqual(sent, windows)
    }

    /// The copy that used to lose its tail: 256,000 bytes in the Mac's lines
    /// is 262,400 in Windows', and a set measured against the Mac's budget
    /// cut the last 256 of them.
    func testAMacCopyThatFitsReachesTheHostWhole() {
        let text = String(repeating: String(repeating: "x", count: 39) + "\n", count: 6_400)
        let (payload, cut) = AgentConnection.clipboardPayload(text)
        XCTAssertFalse(cut)
        let windows = ClipboardBridge.windowsLineEndings(payload)
        XCTAssertEqual(windows.utf8.count, 262_400)
        let (sent, truncated) = AgentConnection.clipboardSetPayload(windows)
        XCTAssertFalse(truncated)
        XCTAssertEqual(sent.utf8.count, windows.utf8.count)
        XCTAssertTrue(sent.utf8.elementsEqual(windows.utf8))
    }

    func testEmptyTextIsNotTruncated() {
        let (text, truncated) = AgentConnection.clipboardPayload("")
        XCTAssertEqual(text, "")
        XCTAssertFalse(truncated)
    }
}
