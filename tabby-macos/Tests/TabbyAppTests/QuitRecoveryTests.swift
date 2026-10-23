#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Quitting keeps every window's tabs for the next launch.
@MainActor
final class QuitRecoveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    /// Found in the M6 walk: quitting with a second, empty window restored no tabs. After the
    /// final save AppKit closes every window "for termination"; each close saved what was
    /// left, and the empty window closed last.
    func testQuittingWithAnEmptyWindowKeepsTheOtherWindowsTabs() throws {
        let full = WindowManager.shared.newWindow(openDefaultTab: false)
        let empty = WindowManager.shared.newWindow(openDefaultTab: false)
        defer {
            RecoveryCoordinator.shared.isTerminating = false
            TestApp.dispose(full)
            TestApp.dispose(empty)
        }
        for name in ["one", "two", "three"] { full.model.openTab(profile: TestApp.profile(name, "sleep 30")) }
        let expected = WindowManager.shared.controllers.flatMap { $0.model.recoveryTokens(includeBuffers: false) }.count
        XCTAssertGreaterThanOrEqual(expected, 3)

        RecoveryCoordinator.shared.saveForTermination()  // applicationWillTerminate
        for controller in [full, empty] {               // NSApplication then closes the windows
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: controller.window))
        }
        XCTAssertEqual(AppServices.shared.recovery.load().count, expected, "the tabs saved on quit survive the window closes")
    }

    /// Found in the M8 walk: config.yaml edited by hand while the app ran was overwritten when
    /// it quit, though nothing had changed in the app. Quitting writes only a change that is
    /// still waiting to be saved.
    func testQuittingKeepsAHandEditWhenNothingChanged() throws {
        let services = AppServices.shared
        services.flushSave()
        let url = services.paths.configFile
        let edited = try String(contentsOf: url, encoding: .utf8) + "# edited by hand\n"
        try edited.write(to: url, atomically: true, encoding: .utf8)
        services.flushPendingSave()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited, "nothing waiting: the file is left alone")

        services.config.set("terminal.bell", .string("visual"))
        defer {
            services.config.set("terminal.bell", nil)
            services.flushSave()
        }
        services.flushPendingSave()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("bell: visual"), "a waiting change is written")
    }
}
#endif
