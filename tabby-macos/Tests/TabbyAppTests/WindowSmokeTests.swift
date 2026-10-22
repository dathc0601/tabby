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
        pump(1.5)
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
            pump(0.5)
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

    func testSettingsWindowKeepsItsSize() {
        SettingsWindowController.show()
        pump(0.5)
        let window = NSApp.windows.first { $0.title == "Settings" }
        defer { window?.orderOut(nil) }
        XCTAssertNotNil(window)
        XCTAssertGreaterThanOrEqual(window?.frame.height ?? 0, 460, "the hosting controller must not shrink the window")
    }
}
#endif
