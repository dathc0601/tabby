#if canImport(AppKit)
import XCTest
@testable import TabbyApp

/// Tab widths and overflow from the design's tab board: fixed tabs are 176 pt and shrink to
/// 120 pt before the strip scrolls; flex tabs share the strip down to 64 pt; pinned tabs are
/// 92 pt; tabs sit 2 pt apart; an overflowing strip makes room for the "+N" menu.
final class TabStripLayoutTests: XCTestCase {
    func testOneFixedTabKeepsItsWidth() {
        let l = TabStripLayout(available: 700, pinned: 0, regular: 1, flex: false)
        XCTAssertEqual(l.regularWidth, 176)
        XCTAssertEqual(l.stripWidth, 176)
        XCTAssertFalse(l.overflows)
    }

    func testFixedTabsShrinkBeforeOverflowing() {
        let l = TabStripLayout(available: 754, pinned: 0, regular: 6, flex: false)
        XCTAssertEqual(l.regularWidth, (754 - 10) / 6, accuracy: 1e-9)
        XCTAssertEqual(l.stripWidth, 754, accuracy: 1e-9)
        XCTAssertFalse(l.overflows)
    }

    func testManyFixedTabsOverflowAtTheMinimum() {
        let l = TabStripLayout(available: 754, pinned: 0, regular: 12, flex: false)
        XCTAssertEqual(l.regularWidth, 120)
        XCTAssertTrue(l.overflows)
        XCTAssertEqual(l.stripWidth, 754 - TabStripLayout.overflowButton, accuracy: 1e-9)
        XCTAssertEqual(l.contentWidth, 12 * 120 + 11 * 2, accuracy: 1e-9)
    }

    func testPinnedTabsAreNarrow() {
        let l = TabStripLayout(available: 800, pinned: 2, regular: 1, flex: false)
        XCTAssertEqual(l.pinnedWidth, 92)
        XCTAssertEqual(l.contentWidth, 92 * 2 + 176 + 2 * 2, accuracy: 1e-9)
        XCTAssertFalse(l.overflows)
    }

    func testFlexTabsFillTheStrip() {
        let l = TabStripLayout(available: 600, pinned: 0, regular: 3, flex: true)
        XCTAssertEqual(l.regularWidth, (600 - 4) / 3, accuracy: 1e-9)
        XCTAssertEqual(l.stripWidth, 600, accuracy: 1e-9)
        XCTAssertFalse(l.overflows)
    }

    func testFlexTabsOverflowAtSixtyFour() {
        let l = TabStripLayout(available: 600, pinned: 0, regular: 20, flex: true)
        XCTAssertEqual(l.regularWidth, 64)
        XCTAssertTrue(l.overflows)
    }

    func testNoTabs() {
        let l = TabStripLayout(available: 600, pinned: 0, regular: 0, flex: false)
        XCTAssertEqual(l.stripWidth, 0)
        XCTAssertFalse(l.overflows)
    }

    func testHiddenTabsAreThoseNotFullyInView() {
        let frames: [ClosedRange<Double>] = [0...100, 102...202, 204...304, 306...406]
        XCTAssertEqual(TabStripLayout.hiddenIndices(frames: frames, viewport: 0...250), [2, 3])
        XCTAssertEqual(TabStripLayout.hiddenIndices(frames: frames, viewport: 150...410), [0, 1])
        XCTAssertEqual(TabStripLayout.hiddenIndices(frames: frames, viewport: 0...500), [])
    }
}
#endif
