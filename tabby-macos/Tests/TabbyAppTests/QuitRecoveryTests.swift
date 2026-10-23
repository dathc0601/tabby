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
}
#endif
