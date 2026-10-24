#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 6: Tabby's `terminal.focusFollowsMouse` and "Focus all tabs"
/// (`MultifocusService.focusAllTabs`).
@MainActor
final class PaneFocusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    override func tearDown() {
        AppServices.shared.config.set("terminal.focusFollowsMouse", .null)
        super.tearDown()
    }

    func testFocusFollowsMouseOnlyWhenOn() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("a", "sleep 30")))
        let first = try XCTUnwrap(tab.focusedPane)
        c.model.split(.right, profile: TestApp.profile("b", "sleep 30"))
        let second = try XCTUnwrap(tab.focusedPane)
        TestApp.pump(0.3)
        let firstView = try XCTUnwrap(c.paneView(for: first))
        firstView.pointerMoved()
        XCTAssertEqual(tab.focusedPaneID, second.id, "off by default")
        AppServices.shared.config.set("terminal.focusFollowsMouse", .bool(true))
        firstView.pointerMoved()
        XCTAssertEqual(tab.focusedPaneID, first.id)
    }

    /// Two tabs, the second split: (controller, panes a, b, c), c focused in the active tab.
    func threePanes() throws -> (MainWindowController, TerminalPane, TerminalPane, TerminalPane) {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        c.window?.setContentSize(NSSize(width: 900, height: 600))
        let one = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("a", "cat")))
        let a = try XCTUnwrap(one.focusedPane)
        TestApp.pump(until: { a.isRunning })
        let two = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("b", "cat")))
        let b = try XCTUnwrap(two.focusedPane)
        c.model.split(.right, profile: TestApp.profile("c", "cat"))
        let p = try XCTUnwrap(two.focusedPane)
        TestApp.pump(until: { b.isRunning && p.isRunning })
        return (c, a, b, p)
    }

    func testFocusAllTabsSendsWhatIsTypedToEveryPaneOfEveryTab() throws {
        let (c, a, b, p) = try threePanes()
        defer { TestApp.dispose(c) }
        XCTAssertTrue(c.runCommand("focus-all-tabs"))
        XCTAssertTrue(c.model.broadcastAllTabs)
        p.engine(try XCTUnwrap(p.engine), send: Data("broadcast-42\r".utf8))
        for pane in [a, b, p] {
            XCTAssertTrue(TestApp.pump(until: { pane.engine?.snapshotText(maxLines: 20).contains("broadcast-42") == true }),
                          "\(pane.profile.name): \(pane.engine?.snapshotText(maxLines: 5) ?? "")")
        }
    }

    func testItEndsOnAClickATabSwitchOrTheCommandAgain() throws {
        let (c, a, _, p) = try threePanes()
        defer { TestApp.dispose(c) }
        c.runCommand("focus-all-tabs")
        p.engineClicked(try XCTUnwrap(p.engine))
        XCTAssertFalse(c.model.broadcastAllTabs, "a click in a terminal")
        c.runCommand("focus-all-tabs")
        let first = try XCTUnwrap(c.model.tabs.first { $0.panes[a.id] != nil })
        c.model.select(first.id)
        XCTAssertFalse(c.model.broadcastAllTabs, "another tab")
        c.runCommand("focus-all-tabs")
        c.runCommand("focus-all-tabs")
        XCTAssertFalse(c.model.broadcastAllTabs, "the command again")
    }

    func testTheWindowSaysSoWhileOn() throws {
        let (c, _, _, p) = try threePanes()
        defer { TestApp.dispose(c) }
        XCTAssertFalse(c.isShowingBroadcastBanner)
        c.runCommand("focus-all-tabs")
        TestApp.pump(0.2)
        XCTAssertTrue(c.isShowingBroadcastBanner)
        XCTAssertEqual(c.broadcastBannerText, "Broadcast mode. Click anywhere to cancel.")
        XCTAssertTrue(c.paneView(for: p)?.showsFocusRing == true)
        let menu = c.terminalContextMenu(for: p)
        XCTAssertEqual(menu.items.first { $0.title == "Broadcast Input to All Tabs" }?.state, .on)
        let tab = try XCTUnwrap(c.model.activeTab)
        XCTAssertNotNil(TabMenu.build(for: tab, actions: c.tabBarActions!).items.first { $0.title == "Broadcast Input to All Tabs" })
        c.runCommand("focus-all-tabs")
        TestApp.pump(0.2)
        XCTAssertFalse(c.isShowingBroadcastBanner)
    }
}
#endif
