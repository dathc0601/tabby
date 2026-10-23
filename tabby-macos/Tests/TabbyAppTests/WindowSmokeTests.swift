#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Boots the real window with a scratch config directory and checks the chrome and the
/// first tab lay out as intended. Guards against regressions that only show up on screen.
@MainActor
final class WindowSmokeTests: XCTestCase {
    func pump(_ seconds: Double) { TestApp.pump(seconds) }

    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    /// Every view the SwiftUI tab bar creates must stay inside the strip reserved for it.
    func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

    func testTabBarStaysInItsStripAndShellOutputIsVisible() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { controller.window?.orderOut(nil) }
        let profile = Profile(id: "local:smoke", type: "local", name: "smoke",
                              options: LocalOptions(command: "/bin/sh", args: ["-c", "printf 'HELLO-FROM-SHELL\\r\\n'; sleep 3"]).configValue)
        _ = controller.model.openTab(profile: profile)
        TestApp.pump(until: {
            controller.model.activePane.flatMap { controller.paneView(for: $0) }?
                .engine.snapshotText(maxLines: 5).contains("HELLO-FROM-SHELL") ?? false
        })
        let content = try XCTUnwrap(controller.window?.contentView)
        content.layoutSubtreeIfNeeded()

        let tabBar = try XCTUnwrap(content.subviews.first { "\(type(of: $0))".hasPrefix("NSHostingView<TabBarView>") })
        let strip = tabBar.frame
        XCTAssertEqual(strip.minY, 0)
        for v in allSubviews(tabBar) {
            let f = v.convert(v.bounds, to: content)
            XCTAssertLessThanOrEqual(f.maxY, strip.maxY + 0.5, "\(type(of: v)) \(f) overflows the tab bar strip \(strip)")
        }

        let pane = try XCTUnwrap(controller.model.activePane)
        let view = try XCTUnwrap(controller.paneView(for: pane))
        let paneFrame = view.convert(view.bounds, to: content)
        XCTAssertEqual(paneFrame.minY, strip.maxY, accuracy: 0.5, "terminal starts right below the tab bar")
        XCTAssertTrue(view.engine.snapshotText(maxLines: 5).contains("HELLO-FROM-SHELL"))
    }

    /// Tabs take the width they need before the empty drag area does (Tabby's
    /// `.tabs { flex: 0 1 auto }` next to `.btn-space { flex: 1 0 1% }`).
    func testTabsTakeTheStripBeforeTheDragArea() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        controller.window?.setContentSize(NSSize(width: 960, height: 600))
        let content = try XCTUnwrap(controller.window?.contentView)
        func dragArea() throws -> NSRect {
            pump(0.3)
            content.layoutSubtreeIfNeeded()
            let tabBar = try XCTUnwrap(content.subviews.first { "\(type(of: $0))".hasPrefix("NSHostingView<TabBarView>") })
            let drag = try XCTUnwrap(allSubviews(tabBar).first { $0 is WindowDragArea.DragView })
            return drag.convert(drag.bounds, to: tabBar)
        }
        controller.model.openTab(profile: TestApp.profile("strip-1", "sleep 30"))
        let one = try dragArea()
        for i in 2...6 { controller.model.openTab(profile: TestApp.profile("strip-\(i)", "sleep 30")) }
        let six = try dragArea()
        XCTAssertGreaterThan(one.width, 400, "one tab is at most 200 pt wide and leaves the rest: \(one)")
        XCTAssertLessThanOrEqual(six.width, 24.5, "six tabs need the whole strip, the drag area keeps its minimum: \(six)")
    }

    /// `swift test` and `swift run` have no app bundle (the test host's main bundle is the
    /// xctest tool, which has an identifier), and UNUserNotificationCenter raises without one.
    /// The banner path only runs while another app is frontmost; whether the test app is
    /// depends on earlier tests (opening Settings activates it), so the test says so itself.
    func testProcessEndedNotificationNeedsAnAppBundle() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        let pane = try XCTUnwrap(controller.model.openTab(profile: TestApp.profile("note", "sleep 30"))?.focusedPane)
        controller.notifyProcessEnded(pane, code: 0, appIsActive: false)
    }

    /// With the tab bar on a side edge, the transparent title bar still spans the whole width,
    /// so the terminal must start below it or its first row turns into a window drag area.
    func testSideTabBarKeepsTerminalBelowTitleBar() throws {
        for side in ["left", "right"] {
            AppServices.shared.config.set("appearance.tabsLocation", .string(side))
            defer { AppServices.shared.config.set("appearance.tabsLocation", nil) }
            let controller = WindowManager.shared.newWindow(openDefaultTab: false)
            defer { controller.window?.orderOut(nil) }
            let profile = Profile(id: "local:side", type: "local", name: "side",
                                  options: LocalOptions(command: "/bin/sh", args: ["-c", "sleep 3"]).configValue)
            _ = controller.model.openTab(profile: profile)
            // Tab views come from an observation callback; slow runners need more than a beat.
            TestApp.pump(until: { controller.model.activePane.flatMap { controller.paneView(for: $0) } != nil })
            let content = try XCTUnwrap(controller.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let pane = try XCTUnwrap(controller.model.activePane)
            let view = try XCTUnwrap(controller.paneView(for: pane))
            let paneFrame = view.convert(view.bounds, to: content)
            XCTAssertGreaterThanOrEqual(paneFrame.minY, 28, "\(side): terminal \(paneFrame) overlaps the title bar")
        }
    }

    /// Connection tabs can be disconnected and reconnected from the Shell menu, not only from
    /// the command palette (neither command has a default shortcut).
    func testShellMenuOffersDisconnectAndReconnect() throws {
        MainMenu.install()
        let shell = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "Shell" }?.submenu)
        let ids = shell.items.compactMap { $0.representedObject as? String }
        XCTAssertTrue(ids.contains("disconnect-tab"), "\(ids)")
        XCTAssertTrue(ids.contains("reconnect-tab"), "\(ids)")
    }

    /// TabbyMac has its own tabs, so macOS must not add its window-tab items (Show Tab Bar,
    /// Merge All Windows, …) to the View and Window menus.
    func testMenusLeaveOutNativeWindowTabbing() {
        MainMenu.install()
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
    }

    /// AppKit adds its own "Enter Full Screen" to a View menu that has no `toggleFullScreen:`
    /// item, so ours must use that action; it keeps the ⌃⌘F shortcut from `hotkeys`.
    func testFullScreenMenuItemUsesTheStandardAction() throws {
        MainMenu.install()
        let view = try XCTUnwrap(NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu)
        let items = view.items.filter { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
        XCTAssertEqual(items.count, 1, "\(view.items.map(\.title))")
        XCTAssertEqual(items.first?.keyEquivalent, "f")
        XCTAssertEqual(items.first?.keyEquivalentModifierMask, [.control, .command])
    }
}
#endif
