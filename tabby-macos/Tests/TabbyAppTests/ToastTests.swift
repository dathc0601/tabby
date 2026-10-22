#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// In-app toasts (the design's "Process completed" toast; sync results use them in 2b).
@MainActor
final class ToastTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func testProcessEndingInABackgroundTabShowsAToast() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let background = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("build", "sleep 0.5; exit 3")))
        c.model.openTab(profile: TestApp.profile("front", "sleep 30"))
        XCTAssertFalse(c.model.activeTab === background)
        TestApp.pump(until: { !c.toasts.toasts.isEmpty })
        let toast = try XCTUnwrap(c.toasts.toasts.first)
        XCTAssertEqual(toast.title, "Process completed")
        XCTAssertTrue(toast.detail.contains("code 3"), toast.detail)
        XCTAssertEqual(toast.tint, .danger, "a non-zero exit is shown in the danger colour")
    }

    func testProcessEndingInTheActiveTabOfTheActiveAppShowsNothing() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("front", "sleep 30"))?.focusedPane)
        c.notifyProcessEnded(pane, code: 0, appIsActive: true)
        XCTAssertTrue(c.toasts.toasts.isEmpty)
        c.notifyProcessEnded(pane, code: 0, appIsActive: false)
        XCTAssertEqual(c.toasts.toasts.first?.tint, .success)
    }

    func testToastsExpireAndStayFew() {
        let center = ToastCenter()
        for i in 0..<5 { center.show(ToastCenter.Toast(symbol: "info.circle", tint: .accent, title: "t\(i)", detail: ""), for: 0.2) }
        XCTAssertEqual(center.toasts.count, 3, "older toasts make room")
        XCTAssertEqual(center.toasts.map(\.title), ["t2", "t3", "t4"])
        TestApp.pump(until: { center.toasts.isEmpty }, timeout: 3)
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testDurationFormatting() {
        XCTAssertEqual(ToastCenter.duration(12), "12s")
        XCTAssertEqual(ToastCenter.duration(192), "3m 12s")
        XCTAssertEqual(ToastCenter.duration(3840), "1h 4m")
    }
}
#endif
