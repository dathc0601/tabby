#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 5: the tab and pane menus' "Notify when done" / "Notify on activity" (Tabby's
/// `TaskCompletionContextMenu`) and how they are delivered (`Notifier`).
@MainActor
final class NotifyWhenDoneTests: XCTestCase {
    var posted: [(title: String, body: String, pane: UUID)] = []

    override func setUp() {
        super.setUp()
        TestApp.boot()
        posted = []
        Notifier.shared.poster = { [unowned self] title, body, pane in self.posted.append((title, body, pane)) }
    }

    override func tearDown() {
        Notifier.shared.poster = nil
        super.tearDown()
    }

    /// A window with one local tab whose shell runs `script`; returns once the pane started.
    func window(_ script: String) throws -> (MainWindowController, TerminalPane) {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("busy", script)))
        let pane = try XCTUnwrap(tab.focusedPane)
        TestApp.pump(until: { pane.isRunning })
        return (c, pane)
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }

    func testTheMenusOfferNotifyWhenDoneWhileAProcessRuns() throws {
        let (c, pane) = try window("set -m; sleep 30; :")
        defer { TestApp.dispose(c) }
        TestApp.pump(until: { pane.activeProcessName != nil })
        let menu = c.terminalContextMenu(for: pane)
        let current = try XCTUnwrap(menu.items.first { $0.title == "Current process: sleep" }, "\(titles(menu))")
        XCTAssertNil(current.action, "a disabled line")
        XCTAssertEqual(menu.items.first { $0.title == "Notify when done" }?.state, .off)
        XCTAssertNotNil(menu.items.first { $0.title == "Notify on activity" })
        XCTAssertEqual(NotifyMenu.items(for: pane).map(\.title), ["Current process: sleep", "Notify when done", "Notify on activity"])
    }

    func testAnIdleShellOffersOnlyNotifyOnActivity() throws {
        let (c, pane) = try window("sleep 30")
        defer { TestApp.dispose(c) }
        TestApp.pump(0.3)
        if pane.activeProcessName == nil {
            XCTAssertEqual(NotifyMenu.items(for: pane).map(\.title), ["Notify on activity"])
        }
        XCTAssertEqual(NotifyMenu.items(for: nil), [], "content tabs have no pane")
    }

    func testTheCommandsArmAndDisarm() throws {
        let (c, pane) = try window("set -m; sleep 30; :")
        defer { TestApp.dispose(c) }
        TestApp.pump(until: { pane.activeProcessName != nil })
        XCTAssertTrue(c.runCommand("notify-when-done"))
        XCTAssertTrue(pane.notifyWhenDone)
        XCTAssertEqual(c.terminalContextMenu(for: pane).items.first { $0.title == "Notify when done" }?.state, .on)
        c.runCommand("notify-when-done")
        XCTAssertFalse(pane.notifyWhenDone)
        c.runCommand("notify-on-activity")
        XCTAssertTrue(pane.notifyOnActivity)
    }

    func testAFinishedProcessPostsWithThePaneAndShowsAToast() throws {
        let (c, pane) = try window("set -m; sleep 1; read x")
        defer { TestApp.dispose(c) }
        TestApp.pump(until: { pane.activeProcessName != nil })
        pane.completionPollInterval = 0.1
        c.runCommand("notify-when-done")
        TestApp.pump(until: { !self.posted.isEmpty }, timeout: 5)
        XCTAssertEqual(posted.first?.title, "Process completed")
        XCTAssertEqual(posted.first?.body, "sleep")
        XCTAssertEqual(posted.first?.pane, pane.id)
        XCTAssertEqual(c.toasts.toasts.last?.title, "Process completed", "★ the toast shows too")
        XCTAssertTrue(c.toasts.toasts.last?.detail.contains("sleep") ?? false)
    }

    func testActivityPostsTheTabTitle() throws {
        let (c, pane) = try window("sleep 30")
        defer { TestApp.dispose(c) }
        c.notifyActivity(pane)
        XCTAssertEqual(posted.first?.title, "Tab activity")
        XCTAssertEqual(posted.first?.body, pane.title)
        XCTAssertEqual(c.toasts.toasts.last?.title, "Tab activity")
    }

    func testOpeningANotificationFocusesItsPane() throws {
        let (c, first) = try window("sleep 30")
        defer { TestApp.dispose(c) }
        c.model.split(.right, profile: TestApp.profile("second", "sleep 30"))
        let second = try XCTUnwrap(c.model.activeTab?.orderedPanes.last)
        c.model.focus(paneID: first.id)
        XCTAssertTrue(c.model.activePane === first)
        XCTAssertTrue(Notifier.shared.focus(paneID: second.id))
        XCTAssertTrue(c.model.activePane === second)
        XCTAssertFalse(Notifier.shared.focus(paneID: UUID()), "a closed pane")
    }

    func testOutsideTheAppBundleNothingReachesTheNotificationCenter() {
        XCTAssertFalse(Notifier.isBundled, "swift test runs from xctest, not TabbyMac.app")
        Notifier.shared.poster = nil
        Notifier.shared.post(title: "t", body: "b", pane: UUID())
    }
}
#endif
