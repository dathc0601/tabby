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
