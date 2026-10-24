#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 6: Tabby's "Rename pane" / "Show pane label" (`CommonOptionsContextMenu`) and
/// rearranging panes (`rearrange-panes`, `SplitTabPaneLabelComponent`, the drop zones).
@MainActor
final class PaneTitleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }

    /// A window with one tab split in two: (controller, tab, left pane, right pane).
    func splitWindow() throws -> (MainWindowController, TabModel, TerminalPane, TerminalPane) {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        c.window?.setContentSize(NSSize(width: 1000, height: 600))
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("a", "sleep 30")))
        let first = try XCTUnwrap(tab.focusedPane)
        c.model.split(.right)
        let second = try XCTUnwrap(tab.focusedPane)
        XCTAssertFalse(first === second)
        TestApp.pump(0.3)
        return (c, tab, first, second)
    }

    func testRenamePaneAndShowPaneLabelOnlyInASplit() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("alone", "sleep 30")))
        let alone = try XCTUnwrap(tab.focusedPane)
        XCTAssertFalse(titles(c.terminalContextMenu(for: alone)).contains("Rename pane"), "Tabby: splits only")

        let (s, _, _, second) = try splitWindow()
        defer { TestApp.dispose(s) }
        var menu = s.terminalContextMenu(for: second)
        XCTAssertTrue(titles(menu).contains("Rename pane"), "\(titles(menu))")
        XCTAssertEqual(menu.items.first { $0.title == "Show pane label" }?.isEnabled, false, "nothing to show yet")
        s.renamePane(second, to: "logs")
        XCTAssertEqual(second.customTitle, "logs")
        XCTAssertTrue(second.customTitleVisible)
        menu = s.terminalContextMenu(for: second)
        let label = try XCTUnwrap(menu.items.first { $0.title == "Show pane label" })
        XCTAssertTrue(label.isEnabled)
        XCTAssertEqual(label.state, .on)
        XCTAssertTrue(s.runCommand("toggle-pane-label"))
        XCTAssertFalse(second.customTitleVisible)
        s.renamePane(second, to: "")
        XCTAssertNil(second.customTitle, "an empty name clears it")
    }

    func testTheLabelShowsTheCustomTitleAtTheTop() throws {
        let (c, tab, first, second) = try splitWindow()
        defer { TestApp.dispose(c) }
        c.renamePane(second, to: "logs")
        TestApp.pump(0.3)
        let view = try XCTUnwrap(c.paneView(for: second))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.customLabel, "logs")
        let frame = try XCTUnwrap(view.customLabelFrame)
        XCTAssertEqual(frame.midX, view.bounds.midX, accuracy: 1)
        XCTAssertEqual(frame.minY, 6, accuracy: 0.5)
        XCTAssertNil(c.paneView(for: first)?.customLabel)
        tab.isRearranging = true
        TestApp.pump(0.2)
        XCTAssertNil(view.customLabel, "hidden while rearranging")
        XCTAssertTrue(view.showsRearrangeOverlay)
        tab.isRearranging = false
        XCTAssertTrue(c.runCommand("toggle-pane-label"))
        TestApp.pump(0.2)
        XCTAssertNil(view.customLabel)
    }

    func testHoldingTheChordShowsTheOverlayUntilReleased() throws {
        let (c, tab, _, _) = try splitWindow()
        defer { TestApp.dispose(c) }
        let manager = HotkeyManager { _ in true }
        manager.reload(from: AppServices.shared.config)
        var events: [String] = []
        manager.onModifierHotkey = { id, down in
            events.append("\(id) \(down)")
            c.modifierHotkey(id, down: down)
        }
        manager.modifiersChanged([.control, .shift])
        XCTAssertTrue(tab.isRearranging)
        manager.modifiersChanged([.control, .shift, .capsLock])
        XCTAssertEqual(events, ["rearrange-panes true"], "caps lock is not a modifier of the chord")
        manager.modifiersChanged([.control])
        XCTAssertFalse(tab.isRearranging)
        manager.modifiersChanged([.control, .shift])
        manager.otherKeyPressed()
        XCTAssertEqual(events, ["rearrange-panes true", "rearrange-panes false", "rearrange-panes true", "rearrange-panes false"],
                       "another key ends it, as Tabby's hotkeyOff$")
    }

    func testDropZones() {
        let (a, b) = (UUID(), UUID())
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let frames = [a: CGRect(x: 0, y: 0, width: 499, height: 600), b: CGRect(x: 500, y: 0, width: 500, height: 600)]
        func zone(_ x: CGFloat, _ y: CGFloat, dragging: UUID = UUID()) -> SplitTreeView.PaneDropZone? {
            SplitTreeView.paneDropZone(at: CGPoint(x: x, y: y), bounds: bounds, frames: frames, dragged: dragging)
        }
        XCTAssertEqual(zone(4, 300)?.relativeTo, nil)
        XCTAssertEqual(zone(4, 300)?.side, .left, "the outer left edge")
        XCTAssertEqual(zone(500, 596)?.side, .bottom)
        XCTAssertNil(zone(500, 596)?.relativeTo, "the outer bottom edge")
        XCTAssertEqual(zone(560, 300, dragging: a)?.relativeTo, b)
        XCTAssertEqual(zone(560, 300, dragging: a)?.side, .left)
        XCTAssertNil(zone(250, 300, dragging: a), "not next to itself")
    }

    func testDroppingAPaneMovesItAndEndsRearranging() throws {
        let (c, tab, first, second) = try splitWindow()
        defer { TestApp.dispose(c) }
        tab.isRearranging = true
        XCTAssertTrue(c.model.movePane(first.id, relativeTo: second.id, side: .right))
        XCTAssertEqual(tab.layout.panes, [second.id, first.id])
        XCTAssertEqual(tab.focusedPaneID, first.id)
        XCTAssertFalse(tab.isRearranging)
        XCTAssertFalse(c.model.movePane(first.id, relativeTo: first.id, side: .left))
    }

    func testAPaneDroppedOnTheTabBarBecomesATab() throws {
        let (c, tab, first, second) = try splitWindow()
        defer { TestApp.dispose(c) }
        XCTAssertTrue(c.model.detachPane(second.id))
        XCTAssertEqual(c.model.tabs.count, 2)
        XCTAssertEqual(tab.layout.panes, [first.id])
        XCTAssertEqual(c.model.activeTab?.focusedPane?.id, second.id)
        XCTAssertFalse(c.model.detachPane(first.id), "the only pane of its tab is a tab already")
    }

    func testTheLabelSurvivesRecovery() throws {
        let (c, _, _, second) = try splitWindow()
        defer { TestApp.dispose(c) }
        c.renamePane(second, to: "logs")
        _ = c.runCommand("toggle-pane-label")
        let state = second.recoveryState(includeBuffer: false)
        XCTAssertEqual(state.customTitle, "logs")
        XCTAssertFalse(state.customTitleVisible)
    }
}
#endif
