#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Docked ("Quake") mode, a port of `tabby-electron/src/services/docking.service.ts`.
@MainActor
final class DockingTests: XCTestCase {
    var config: ConfigStore { AppServices.shared.config }

    /// The window `DockController` docks: the first terminal window.
    func dockedWindow() throws -> NSWindow {
        TestApp.boot()
        if WindowManager.shared.controllers.isEmpty { WindowManager.shared.newWindow(openDefaultTab: false) }
        let window = try XCTUnwrap(WindowManager.shared.controllers.first?.window)
        addTeardownBlock { @MainActor in
            for key in ["appearance.dock", "appearance.dockAlwaysOnTop"] { AppServices.shared.config.set(key, nil) }
            DockController.shared.apply()
            window.orderOut(nil)
        }
        return window
    }

    func dock(_ side: String, alwaysOnTop: Bool = true) {
        config.set("appearance.dock", .string(side))
        config.set("appearance.dockAlwaysOnTop", .bool(alwaysOnTop))
        DockController.shared.apply()
    }

    /// Tabby calls `setAlwaysOnTop(dockAlwaysOnTop)` every time it docks, so turning the option
    /// off lowers the window again; undocking also returns it to its own Space.
    func testAlwaysOnTopFollowsTheSetting() throws {
        let window = try dockedWindow()
        dock("top")
        XCTAssertEqual(window.level, .floating)
        dock("top", alwaysOnTop: false)
        XCTAssertEqual(window.level, .normal, "turning Always on top off lowers the docked window")
        dock("off", alwaysOnTop: false)
        XCTAssertEqual(window.level, .normal)
        XCTAssertFalse(window.collectionBehavior.contains(.canJoinAllSpaces), "an undocked window stays on its own Space")
    }
}
#endif
