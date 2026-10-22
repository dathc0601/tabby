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

    /// Settings opens as a tab of the docked window, as in Tabby, so an always-on-top docked
    /// terminal can no longer cover it (it did when Settings was a window of its own).
    func testSettingsOpensInsideTheDockedWindow() throws {
        let window = try dockedWindow()
        dock("top")
        let controller = try XCTUnwrap(window.windowController as? MainWindowController)
        defer { controller.model.tabs.filter { $0.content != nil }.forEach { controller.model.closeTab($0.id) } }
        XCTAssertTrue(controller.runCommand("settings"))
        XCTAssertEqual(controller.model.activeTab?.content, .settings)
        XCTAssertEqual(window.level, .floating)
        XCTAssertFalse(NSApp.windows.contains { $0.isVisible && !($0.windowController is MainWindowController) && $0.title == "Settings" },
                       "no separate Settings window")
    }

    /// Tabby docks on `appearance.dockScreen` when it names a connected display (Electron's
    /// display id is the CGDirectDisplayID) and otherwise on the display under the mouse. The
    /// window's own screen was used, so a window left on another display docked there.
    func testDocksOnTheDisplayUnderTheMouse() throws {
        let screens = NSScreen.screens
        for screen in screens {
            let middle = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
            XCTAssertEqual(DockController.screen(for: "current", near: middle), screen, "\(screen.frame)")
        }
        let last = try XCTUnwrap(screens.last)
        let id = try XCTUnwrap(last.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        XCTAssertEqual(DockController.screen(for: .int(id.intValue), near: .zero), last, "a display picked by id")
    }

    /// A docked window has no traffic lights (the design's Quake panel); the tab strip starts at
    /// the edge instead of after them.
    func testDockedWindowHidesTheTrafficLights() throws {
        let window = try dockedWindow()
        dock("top")
        TestApp.pump(until: { window.standardWindowButton(.closeButton)?.isHidden == true })
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true)
        dock("off")
        TestApp.pump(until: { window.standardWindowButton(.closeButton)?.isHidden == false })
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)
    }

    /// Dragging the free edge of a docked window changes `appearance.dockFill`, so the next
    /// dock keeps the new size.
    func testResizingADockedWindowKeepsTheNewSize() throws {
        let window = try dockedWindow()
        dock("top")
        let controller = try XCTUnwrap(window.windowController as? MainWindowController)
        let area = try XCTUnwrap(window.screen?.visibleFrame)
        var frame = window.frame
        frame.size.height = area.height * 0.4
        frame.origin.y = area.maxY - frame.height
        window.setFrame(frame, display: false)
        controller.windowDidEndLiveResize(Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        XCTAssertEqual(config.double("appearance.dockFill") ?? 0, 0.4, accuracy: 0.011)
        config.set("appearance.dockFill", nil)
    }
}
#endif
