#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// The pane context menu follows the design: clipboard, a Split submenu, broadcast and clear,
/// then the session; items show their hotkeys.
@MainActor
final class ContextMenuTests: XCTestCase {
    func testTerminalMenuGroupsSplitsAndShowsHotkeys() throws {
        TestApp.boot()
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("menu", "sleep 30"))?.focusedPane)
        let menu = c.terminalContextMenu(for: pane)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(Array(titles.prefix(3)), ["Copy", "Paste", "Copy Current Path"])
        let split = try XCTUnwrap(menu.items.first { $0.title == "Split" }?.submenu)
        XCTAssertEqual(split.items.map(\.title), ["Split Up", "Split Right", "Split Down", "Split Left"])
        XCTAssertEqual(menu.items.first { $0.title == "Copy" }?.keyEquivalent, "c")
        XCTAssertTrue(titles.contains("Restart"), "local shells restart rather than reconnect: \(titles)")
        XCTAssertFalse(titles.contains("Disconnect"))
    }
}
#endif
