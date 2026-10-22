#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Tab and pane management as Tabby does it (`AppService`, `SplitTabComponent`,
/// `MultifocusService`), on real windows with a scratch config directory.
@MainActor
final class TabManagementTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func pump(_ seconds: Double) { TestApp.pump(seconds) }

    /// A window model with tabs named `names`, in that order. Panes never start: no view is attached.
    func makeModel(_ names: String...) -> (WindowModel, [TabModel]) {
        let model = WindowModel()
        let tabs = names.compactMap { model.openTab(profile: TestApp.profile($0, "sleep 30")) }
        addTeardownBlock { @MainActor in
            for tab in model.tabs { for pane in tab.orderedPanes { pane.close() } }
        }
        return (model, tabs)
    }

    func names(_ model: WindowModel) -> [String] {
        model.tabs.map { $0.focusedPane?.profile.name ?? "?" }
    }

    // MARK: Placement (`AppService.duplicateTab` / `reopenLastTab`)

    func testDuplicateOpensRightAfterTheOriginal() {
        let (model, tabs) = makeModel("a", "b", "c")
        model.duplicateTab(tabs[0].id)
        XCTAssertEqual(names(model), ["a", "a", "b", "c"])
        XCTAssertFalse(model.tabs[1] === tabs[0])
        XCTAssertTrue(model.activeTab === model.tabs[1], "the copy is selected")
    }

    func testReopenedTabOpensRightAfterTheActiveTab() {
        let (model, tabs) = makeModel("a", "b", "c")
        model.closeTab(tabs[2].id)
        model.select(tabs[0].id)
        model.reopenLastTab()
        XCTAssertEqual(names(model), ["a", "c", "b"])
        XCTAssertTrue(model.activeTab === model.tabs[1])
    }

    func testRestoredTabsAppendInOrder() throws {
        let (model, tabs) = makeModel("a", "b")
        let token = try XCTUnwrap(tabs[1].recoveryToken())
        model.select(tabs[0].id)
        model.restore(token)
        XCTAssertEqual(names(model), ["a", "b", "b"], "launch recovery and saved layouts keep appending")
    }

    // MARK: Pinned tabs (`AppService.pinTab` / `getTabReorderBounds` / `closeTab`)

    func testPinningMovesTheTabToThePinnedGroup() {
        let (model, tabs) = makeModel("a", "b", "c", "d")
        model.togglePinned(tabs[2].id)
        XCTAssertEqual(names(model), ["c", "a", "b", "d"])
        model.togglePinned(tabs[1].id)
        XCTAssertEqual(names(model), ["c", "b", "a", "d"], "pinned tabs keep their pin order")
        model.togglePinned(tabs[2].id)
        XCTAssertEqual(names(model), ["b", "c", "a", "d"], "unpinning moves to the start of the unpinned tabs")
        XCTAssertFalse(tabs[2].isPinned)
    }

    func testTabsMoveOnlyWithinTheirGroup() {
        let (model, tabs) = makeModel("a", "b", "c", "d")
        model.togglePinned(tabs[0].id)
        model.togglePinned(tabs[1].id)
        model.moveTab(tabs[3].id, to: 0)
        XCTAssertEqual(names(model), ["a", "b", "d", "c"], "dragging an unpinned tab stops after the pinned ones")
        model.moveTab(tabs[0].id, to: 3)
        XCTAssertEqual(names(model), ["b", "a", "d", "c"], "dragging a pinned tab stops at the last pinned slot")
        model.select(tabs[3].id)
        model.moveActiveTab(by: -1)
        XCTAssertEqual(names(model), ["b", "a", "c", "d"], "⌘⇧← past the boundary wraps within the group (cycleTabs)")
    }

    func testCloseTabIgnoresPinnedTabs() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        let pinned = try XCTUnwrap(controller.model.openTab(profile: TestApp.profile("pin", "sleep 30")))
        controller.runCommand("pin-tab")
        XCTAssertTrue(pinned.isPinned)
        controller.runCommand("close-tab")
        controller.requestCloseTab(pinned)
        XCTAssertEqual(controller.model.tabs.count, 1, "⌘W and the tab's Close do nothing on a pinned tab")
    }

    /// Tabby's bulk closes run each tab through `canClose`: idle tabs close, busy ones ask.
    func testCloseOtherTabsAsksBeforeClosingBusyTabs() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            TestApp.dispose(controller)
        }
        let model = controller.model
        let busy = try XCTUnwrap(model.openTab(profile: TestApp.profile("busy", "set -m; sleep 30; :")))
        let idle = try XCTUnwrap(model.openTab(profile: TestApp.profile("idle", "sleep 30")))
        let pinned = try XCTUnwrap(model.openTab(profile: TestApp.profile("pinned", "sleep 30")))
        model.togglePinned(pinned.id)
        let keep = try XCTUnwrap(model.openTab(profile: TestApp.profile("keep", "sleep 30")))
        for tab in model.tabs { model.select(tab.id); pump(0.6) }
        XCTAssertNotNil(busy.focusedPane?.activeProcessName, "precondition: the busy tab has a foreground child")

        model.select(keep.id)
        controller.runCommand("close-other-tabs")
        pump(0.3)
        XCTAssertFalse(model.tabs.contains { $0 === idle }, "idle tabs close at once")
        XCTAssertTrue(model.tabs.contains { $0 === busy }, "the busy tab waits for the answer")
        XCTAssertTrue(model.tabs.contains { $0 === pinned }, "pinned tabs stay")
        let sheet = try XCTUnwrap(controller.window?.attachedSheet, "a confirmation is shown")
        controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        pump(0.3)
        XCTAssertFalse(model.tabs.contains { $0 === busy }, "confirming closes it")
        XCTAssertEqual(names(model), ["pinned", "keep"])
    }

    // MARK: Explode and combine (`AppService.explodeTab` / `combineTabsInto`)

    func paneID(_ tab: TabModel) -> UUID { tab.layout.panes[0] }

    func testExplodedPanesOpenAtTheEnd() {
        let (model, tabs) = makeModel("x", "t", "y")
        model.select(tabs[1].id)
        model.split(.right)
        model.split(.bottom)
        let extra = Array(tabs[1].layout.panes.dropFirst())
        model.explodeActiveTab()
        XCTAssertEqual(model.tabs.count, 5)
        XCTAssertTrue(model.tabs[0] === tabs[0] && model.tabs[1] === tabs[1] && model.tabs[2] === tabs[2])
        XCTAssertEqual(model.tabs[3...].map(\.layout.panes), extra.map { [$0] }, "each pane becomes a tab at the end")
        XCTAssertTrue(model.activeTab === model.tabs[4])
    }

    func testCombineLaysThePanesOutInAGrid() {
        let (model, tabs) = makeModel("a", "b", "c", "d")
        let (a, b, c, d) = (paneID(tabs[0]), paneID(tabs[1]), paneID(tabs[2]), paneID(tabs[3]))
        model.select(tabs[0].id)
        model.combineTabs()
        XCTAssertEqual(model.tabs.count, 1)
        let row1 = SplitContainer(orientation: .horizontal, children: [.leaf(a), .leaf(b)])
        let row2 = SplitContainer(orientation: .horizontal, children: [.leaf(c), .leaf(d)])
        XCTAssertEqual(tabs[0].layout.root, SplitContainer(orientation: .vertical, children: [.container(row1), .container(row2)]),
                       "2×2 grid with equal sizes")
    }

    func testCombineForgetsTheRemovedTabs() throws {
        let (model, tabs) = makeModel("a", "b", "c")
        model.select(tabs[0].id)
        model.combineTabs()
        let new = try XCTUnwrap(model.openTab(profile: TestApp.profile("n", "sleep 30")))
        model.selectMRU(-1)
        XCTAssertTrue(model.activeTab === tabs[0], "previous-mru-tab reaches the combined tab, not a removed one")
        XCTAssertFalse(model.activeTab === new)
    }

    // MARK: Broadcast (`pane-focus-all`)

    /// Tabby marks every pane focused while broadcasting (`_allFocusMode || child === focusedTab`).
    func testBroadcastShowsTheFocusRingOnEveryPane() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        let tab = try XCTUnwrap(controller.model.openTab(profile: TestApp.profile("ring", "sleep 30")))
        controller.model.split(.right)
        let content = try XCTUnwrap(controller.window?.contentView)
        pump(0.3)
        content.layoutSubtreeIfNeeded()
        let views = tab.orderedPanes.compactMap { controller.paneView(for: $0) }
        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(views.filter(\.showsFocusRing).count, 1)

        controller.runCommand("pane-focus-all")
        pump(0.3)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(views.filter(\.showsFocusRing).count, 2, "every pane looks focused while broadcasting")

        controller.runCommand("pane-focus-all")
        pump(0.3)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(views.filter(\.showsFocusRing).count, 1)
    }

    /// Tabby pastes into every pane while broadcasting (`forEachFocusedTerminalPane(tab => tab.paste())`).
    func testBroadcastPastesIntoEveryPane() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        let tab = try XCTUnwrap(controller.model.openTab(profile: TestApp.profile("paste", "exec cat")))
        controller.model.split(.right)
        pump(1.5)
        controller.runCommand("pane-focus-all")
        try XCTUnwrap(tab.focusedPane).paste("PASTED-EVERYWHERE")
        pump(0.8)
        for pane in tab.orderedPanes {
            let text = try XCTUnwrap(controller.paneView(for: pane)).engine.snapshotText(maxLines: 5)
            XCTAssertTrue(text.contains("PASTED-EVERYWHERE"), "pane shows \(text.debugDescription)")
        }
    }
}
#endif
