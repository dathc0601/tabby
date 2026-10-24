#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// The tab header's menu (right-click and the "…" button). M10: SwiftUI's `.contextMenu`
/// kept the menu it built at the header's last redraw, so with the pointer resting on the tab
/// a process started later had no "Notify when done". The menu is now built when it opens.
@MainActor
final class TabMenuTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }

    /// The right-click area of `tab`'s header in the window's tab bar.
    func menuArea(in c: MainWindowController, for tab: TabModel) -> ContextMenuView? {
        func find(_ view: NSView) -> ContextMenuView? {
            if let v = view as? ContextMenuView, v.tabID == tab.id { return v }
            for sub in view.subviews { if let v = find(sub) { return v } }
            return nil
        }
        return c.window?.contentView.flatMap(find)
    }

    func rightClick(_ c: MainWindowController) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: c.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                         clickCount: 1, pressure: 1))
    }

    func testTheTabMenuIsBuiltWhenItOpens() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("busy", "set -m; sleep 30; :")))
        let pane = try XCTUnwrap(tab.focusedPane)
        TestApp.pump(until: { pane.activeProcessName != nil })
        TestApp.pump(0.3)
        let area = try XCTUnwrap(menuArea(in: c, for: tab), "the tab header has a right-click area")
        let menu = try XCTUnwrap(area.menu(for: try rightClick(c)))
        XCTAssertTrue(titles(menu).contains("Current process: sleep"), "\(titles(menu))")
        XCTAssertTrue(titles(menu).contains("Pin Tab"))
        c.model.togglePinned(tab.id)
        XCTAssertTrue(titles(try XCTUnwrap(area.menu(for: try rightClick(c)))).contains("Unpin Tab"),
                      "the menu reflects the tab as it is when it opens")
    }

    func testTheItemsRunTheirCommands() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("idle", "sleep 30")))
        TestApp.pump(0.3)
        var commands: [String] = []
        var actions: TabBarActions = c.tabBarActions
        actions.command = { id, _ in commands.append(id) }
        let menu = TabMenu.build(for: tab, actions: actions)
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == "Duplicate Tab" })
        menu.performActionForItem(at: index)
        XCTAssertEqual(commands, ["duplicate-tab"])
        let colours = try XCTUnwrap(menu.items.first { $0.title == "Colour" }?.submenu)
        XCTAssertEqual(colours.items.first?.title, "None")
        XCTAssertEqual(colours.items.first?.state, .on, "no colour yet")
        let split = try XCTUnwrap(menu.items.first { $0.title == "Split" }?.submenu)
        XCTAssertEqual(titles(split), ["Split Up", "Split Right", "Split Down", "Split Left"])
    }

    func testContentTabsGetTheShortMenu() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openSettings()
        let tab = try XCTUnwrap(c.model.activeTab)
        let menu = TabMenu.build(for: tab, actions: c.tabBarActions!)
        XCTAssertFalse(titles(menu).contains("Rename Tab…"))
        XCTAssertFalse(titles(menu).contains("Split"))
        XCTAssertTrue(titles(menu).contains("Close Tab"))
    }
}
#endif
