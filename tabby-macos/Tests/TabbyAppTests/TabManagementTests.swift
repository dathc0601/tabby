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
