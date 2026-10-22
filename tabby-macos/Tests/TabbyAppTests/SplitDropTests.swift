#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Dropping a tab on a pane splits that pane and moves the tab's panes in (the design's drop
/// zones; Tabby's drag of a tab into a split).
@MainActor
final class SplitDropTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func testDroppingATabOnAPaneSplitsIt() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let target = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("target", "sleep 30")))
        let source = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("source", "sleep 30")))
        let targetPane = try XCTUnwrap(target.focusedPane?.id)
        let moved = try XCTUnwrap(source.focusedPane)
        TestApp.pump(until: { moved.state == .running })
        XCTAssertTrue(c.model.dropTab(source.id, onto: targetPane, side: .right))
        XCTAssertEqual(c.model.tabs.count, 1, "the dropped tab is gone")
        XCTAssertEqual(target.layout.panes, [targetPane, moved.id])
        XCTAssertTrue(c.model.activeTab === target)
        XCTAssertEqual(target.focusedPaneID, moved.id)
        XCTAssertEqual(moved.state, .running, "the moved pane keeps its session")
    }

    func testDroppingASplitTabKeepsItsLayout() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let target = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("target", "sleep 30")))
        let source = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("a", "sleep 30")))
        c.model.split(.bottom, profile: TestApp.profile("b", "sleep 30"))
        XCTAssertEqual(source.panes.count, 2)
        XCTAssertTrue(c.model.dropTab(source.id, onto: try XCTUnwrap(target.focusedPane?.id), side: .left))
        XCTAssertEqual(target.panes.count, 3)
        XCTAssertEqual(c.model.tabs.count, 1)
    }

    func testDropsThatMakeNoSenseAreRefused() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("self", "sleep 30")))
        XCTAssertFalse(c.model.dropTab(tab.id, onto: try XCTUnwrap(tab.focusedPane?.id), side: .right), "onto itself")
        c.model.openSettings()
        let settings = try XCTUnwrap(c.model.activeTab)
        XCTAssertFalse(c.model.dropTab(settings.id, onto: try XCTUnwrap(tab.focusedPane?.id), side: .right), "Settings has no panes")
        XCTAssertEqual(c.model.tabs.count, 2)
    }
}
#endif
