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
    static var booted = false

    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    override func setUp() {
        super.setUp()
        guard !Self.booted else { return }
        Self.booted = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabbymac-smoke-\(UUID().uuidString.prefix(6))").path
        setenv("TABBYMAC_CONFIG_DIRECTORY", dir, 1)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        AppServices.shared.start()
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
