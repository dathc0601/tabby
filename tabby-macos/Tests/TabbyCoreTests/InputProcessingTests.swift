import XCTest
@testable import TabbyCore

/// Tabby's `InputProcessor`: what the Backspace key sends, per profile (`input.backspace`).
final class InputProcessingTests: XCTestCase {
    func testBackspaceModes() {
        let del = Data([0x7f])
        XCTAssertEqual(InputProcessing.translate(del, backspace: "backspace"), Data([0x7f]))
        XCTAssertEqual(InputProcessing.translate(del, backspace: nil), Data([0x7f]))
        XCTAssertEqual(InputProcessing.translate(del, backspace: "ctrl-?"), Data([0x7f]))
        XCTAssertEqual(InputProcessing.translate(del, backspace: "ctrl-h"), Data([0x08]))
        XCTAssertEqual(InputProcessing.translate(del, backspace: "delete"), Data("\u{1b}[3~".utf8))
    }

    func testOnlyALoneBackspaceIsTranslated() {
        XCTAssertEqual(InputProcessing.translate(Data("a\u{7f}".utf8), backspace: "ctrl-h"), Data("a\u{7f}".utf8), "pasted text is left alone")
        XCTAssertEqual(InputProcessing.translate(Data("x".utf8), backspace: "ctrl-h"), Data("x".utf8))
    }

    func testTheModeIsReadFromTheProfile() {
        XCTAssertEqual(InputProcessing.backspaceMode(["input": ["backspace": "ctrl-h"]]), "ctrl-h")
        XCTAssertNil(InputProcessing.backspaceMode(["host": "x"]))
    }
}
