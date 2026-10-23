#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Tabby keeps a margin around the terminal (`baseTerminalTab` `.content`:
/// `max(0px, 30px * var(--spaciness) - 15px)`), painted in the terminal's background colour.
/// Found in the M6 walk: TabbyMac drew the first column against the window edge.
@MainActor
final class PaneMarginTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    override func tearDown() {
        AppServices.shared.config.set("appearance.spaciness", nil)
        super.tearDown()
    }

    func paneView(_ controller: MainWindowController, _ tab: TabModel) -> PaneContainerView? {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return tab.focusedPane.flatMap { controller.paneView(for: $0) }
    }

    func testTheTerminalSitsInsideTabbysMargin() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        let tab = try XCTUnwrap(controller.model.openTab(profile: TestApp.profile("margin", "sleep 30")))
        TestApp.pump(until: { (self.paneView(controller, tab)?.bounds.width ?? 0) > 100 })
        let view = try XCTUnwrap(paneView(controller, tab))
        XCTAssertEqual(view.engine.frame, view.bounds.insetBy(dx: 15, dy: 15))

        let background = AppServices.shared.theme.scheme(for: tab.focusedPane!.profile).backgroundRGB.nsColor
        XCTAssertEqual(view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)), background,
                       "the margin shows the terminal background")

        AppServices.shared.config.set("appearance.spaciness", .double(1.5))
        TestApp.pump(until: { view.engine.frame == view.bounds.insetBy(dx: 30, dy: 30) })
        XCTAssertEqual(view.engine.frame, view.bounds.insetBy(dx: 30, dy: 30), "the margin follows spaciness")
    }
}
#endif
