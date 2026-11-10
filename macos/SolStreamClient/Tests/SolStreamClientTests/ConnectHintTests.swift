import AppKit
import XCTest
import DesignSystem
@testable import SolStreamClient

/// The connect window's hint is held at two lines, so every hint has to fit
/// in two: the ones cut off before were the ones saying how to get past a
/// problem.
final class ConnectHintTests: XCTestCase {
    func testEveryHintFitsInTwoLines() {
        // A long MagicDNS name, and two found PCs, as long as real ones get.
        let hints = ConnectHint.all(address: "desktop-k3j9qx.tail1a2b3c.ts.net",
                                    names: "DESKTOP-K3J9QX, GAMING-RIG")
        // A little narrower than the label, for the text field's own insets.
        let width = ConnectHint.width - 6
        let twoLines = ceil(DS.body.boundingRectForFont.height) * 2
        for hint in hints {
            let height = NSAttributedString(string: hint, attributes: [.font: DS.body])
                .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            XCTAssertLessThanOrEqual(ceil(height), twoLines, "too long for two lines: \(hint)")
        }
    }
}
