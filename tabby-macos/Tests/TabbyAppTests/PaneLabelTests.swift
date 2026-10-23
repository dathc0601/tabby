#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Design C1b: in a split every pane shows `n · title` at its top-right; the connection chip
/// takes that place while it shows. A single pane has no label.
@MainActor
final class PaneLabelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func testTheCornerShowsTheChipOrTheLabel() {
        func corner(_ state: TerminalPane.ConnectionState?, hovering: Bool = false, popover: Bool = false, label: Int?) -> PaneCorner {
            PaneCorner.content(state: state, hovering: hovering, popoverOpen: popover, labelIndex: label)
        }
        XCTAssertEqual(corner(.connected, hovering: true, label: 2), .chip, "hovering shows the chip")
        XCTAssertEqual(corner(.connected, label: 2), .label(2), "a quiet connected pane shows its label")
        XCTAssertEqual(corner(.disconnected, label: 2), .chip, "a dropped connection always shows the chip")
        XCTAssertEqual(corner(.connecting, label: 1), .chip)
        XCTAssertEqual(corner(.connected, popover: true, label: 2), .chip, "the chip stays while its popover is open")
        XCTAssertEqual(corner(nil, hovering: true, label: 1), .none, "review: the label stands aside for the text under the pointer")
        XCTAssertEqual(corner(nil, label: 1), .label(1), "a local pane has no chip")
        XCTAssertEqual(corner(nil, label: nil), .none)
        XCTAssertEqual(corner(.connected, label: nil), .none, "a single pane has no label")
    }

    /// Review: a popover's button disappears when its session ends (the popover with it), and
    /// its "open" flag was left set, keeping the chip up after reconnecting.
    func testADroppedConnectionClosesThePopoverFlag() {
        let overlay = PaneOverlayState()
        overlay.popoverOpen = true
        overlay.connectionChanged(to: .connected)
        XCTAssertTrue(overlay.popoverOpen)
        overlay.connectionChanged(to: .disconnected)
        XCTAssertFalse(overlay.popoverOpen)
        overlay.popoverOpen = true
        overlay.connectionChanged(to: nil)
        XCTAssertFalse(overlay.popoverOpen)
    }

    func testTheLabelText() {
        XCTAssertEqual(PaneCorner.labelText(index: 2, title: "Core switch"), "2 · Core switch")
    }

    func testEveryPaneOfASplitIsNumberedInOrder() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("a", "sleep 30")))
        func views() -> [PaneContainerView] {
            c.window?.contentView?.layoutSubtreeIfNeeded()
            return tab.orderedPanes.compactMap { c.paneView(for: $0) }
        }
        TestApp.pump(until: { views().count == 1 })
        XCTAssertEqual(views().map(\.labelIndex), [nil], "a single pane has no label")
        c.model.split(.right, profile: TestApp.profile("b", "sleep 30"))
        TestApp.pump(until: { views().map(\.labelIndex) == [1, 2] })
        XCTAssertEqual(views().map(\.labelIndex), [1, 2])
        tab.maximizedPaneID = tab.orderedPanes.first?.id
        TestApp.pump(until: { views().first?.labelIndex == nil })
        XCTAssertEqual(views().first?.labelIndex, nil, "a maximised pane is alone")
    }
}
#endif
