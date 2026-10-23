#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyApp

/// Where the overlays of a pane go. The design puts the SSH status chip in the top-right
/// corner (`top: 8px; right: 12px`); found in the M6 walk drawn top-left over the first line.
@MainActor
final class PaneOverlayLayoutTests: XCTestCase {
    /// The chip view pads itself by 8 pt, so its frame sits 8 pt outside the visible capsule.
    func testTheChipSitsInTheTopRightCorner() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let frame = PaneContainerView.chipFrame(in: bounds, size: CGSize(width: 300, height: 44), search: nil)
        XCTAssertEqual(frame.maxX - 8, bounds.maxX - 12, "12 pt from the right edge")
        XCTAssertEqual(frame.minY + 8, 8, "8 pt from the top")
        XCTAssertEqual(frame.size, CGSize(width: 300, height: 44))
    }

    func testTheChipGoesUnderAnOpenSearchBar() {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let search = CGRect(x: 400, y: 8, width: 388, height: 36)
        let frame = PaneContainerView.chipFrame(in: bounds, size: CGSize(width: 300, height: 44), search: search)
        XCTAssertEqual(frame.minY + 8, search.maxY + 6, "below the search bar")
        XCTAssertEqual(frame.maxX - 8, bounds.maxX - 12)
    }
}
#endif
