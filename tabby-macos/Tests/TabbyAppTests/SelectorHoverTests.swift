#if canImport(AppKit)
import XCTest
@testable import TabbyApp

/// Found in the M8 walk: with the pointer resting over the selector, typing "m8 key" moved the
/// selection to the row that slid under the pointer, and Return opened Quick connect to a
/// host called "m8 key" instead of the profile. Tabby's selector never selects on hover.
final class SelectorHoverTests: XCTestCase {
    func testOnlyAMovingPointerTakesTheSelection() {
        let resting = CGPoint(x: 400, y: 300)
        var hover = HoverSelection(pointer: resting)
        XCTAssertFalse(hover.shouldSelect(pointer: resting), "a row appeared under the resting pointer")
        XCTAssertFalse(hover.shouldSelect(pointer: resting), "the list filtered under it again")
        let moved = CGPoint(x: 400, y: 334)
        XCTAssertTrue(hover.shouldSelect(pointer: moved), "the pointer moved onto a row")
        XCTAssertFalse(hover.shouldSelect(pointer: moved), "then rows changed under it while typing")
    }
}
#endif
