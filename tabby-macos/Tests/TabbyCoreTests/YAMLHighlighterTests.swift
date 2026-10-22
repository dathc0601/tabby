import XCTest
@testable import TabbyCore

/// Token kinds for the Config file editor's syntax colours (keys, strings, numbers, booleans,
/// comments), as UTF-16 ranges so NSTextView can apply them directly.
final class YAMLHighlighterTests: XCTestCase {
    private func spans(_ line: String) -> [String] {
        let utf16 = Array(line.utf16)
        return YAMLHighlighter.tokens(in: line).map { t in
            "\(t.kind):\(String(decoding: utf16[t.range], as: UTF16.self))"
        }
    }

    func testKeyAndScalarKinds() {
        XCTAssertEqual(spans("  font: Menlo"), ["key:font", "string:Menlo"])
        XCTAssertEqual(spans("version: 4"), ["key:version", "number:4"])
        XCTAssertEqual(spans("opacity: 0.92"), ["key:opacity", "number:0.92"])
        XCTAssertEqual(spans("vibrancy: true"), ["key:vibrancy", "bool:true"])
        XCTAssertEqual(spans("vault: null"), ["key:vault", "bool:null"])
    }

    func testCommentsAndListItems() {
        XCTAssertEqual(spans("# Tabby configuration"), ["comment:# Tabby configuration"])
        XCTAssertEqual(spans("    - ⌘-Shift-D"), ["string:⌘-Shift-D"])
        XCTAssertEqual(spans("  - name: prod-web-01"), ["key:name", "string:prod-web-01"])
        XCTAssertEqual(spans("    color: \"#ec6a6a\"  # red"), ["key:color", "string:\"#ec6a6a\"", "comment:# red"])
    }

    func testKeysWithoutValuesAndBlankLines() {
        XCTAssertEqual(spans("appearance:"), ["key:appearance"])
        XCTAssertEqual(spans(""), [])
        XCTAssertEqual(spans("   "), [])
    }

    func testDocumentRangesAreOffsetByLine() {
        let doc = "a: 1\nb: x\n"
        let tokens = YAMLHighlighter.tokens(inDocument: doc)
        let utf16 = Array(doc.utf16)
        XCTAssertEqual(tokens.map { String(decoding: utf16[$0.range], as: UTF16.self) }, ["a", "1", "b", "x"])
    }
}
