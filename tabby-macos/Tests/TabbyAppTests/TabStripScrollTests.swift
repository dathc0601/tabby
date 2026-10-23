#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// The active tab stays in view in an overflowing tab strip.
@MainActor
final class TabStripScrollTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    /// The tab strip's scroll view: the only horizontally overflowing one in a terminal window.
    func tabStrip(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
           document.frame.width > scroll.contentView.bounds.width + 1 {
            return scroll
        }
        for sub in view.subviews { if let found = tabStrip(in: sub) { return found } }
        return nil
    }

    func token(_ name: String, pinned: Bool) -> RecoveryToken {
        let pane = PaneRecovery(type: "app:local-tab", profile: TestApp.profile(name, "sleep 30"))
        return .split(orientation: .horizontal, ratios: [1], children: [.pane(pane)], pinned: pinned, customTitle: name, color: nil)
    }

    /// Found in the M6 walk: after a restore the active first tab sat partly under the
    /// traffic lights, and the overflow menu counted it as hidden.
    func testARestoredWindowShowsItsActiveFirstTabWhole() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        controller.window?.setContentSize(NSSize(width: 706, height: 500))
        // What RecoveryCoordinator.restore(into:) does.
        for (index, name) in ["a", "b", "c", "d", "e"].enumerated() {
            controller.model.restore(token(name, pinned: index < 2))
        }
        controller.model.select(controller.model.tabs[0].id)
        let content = try XCTUnwrap(controller.window?.contentView)
        TestApp.pump(until: { content.layoutSubtreeIfNeeded(); return self.tabStrip(in: content) != nil })
        TestApp.pump(0.5)
        let strip = try XCTUnwrap(tabStrip(in: content), "the strip overflows at this width")
        XCTAssertEqual(strip.contentView.bounds.minX, 0, accuracy: 0.5, "the first tab is the active one")
    }

    /// The strip only scrolled when the active tab changed, so a narrower window (or a strip
    /// laid out again after the window moved, as seen at launch in the M6 walk) left the
    /// active tab partly out of view.
    func testTheActiveTabStaysInViewWhenTheWindowNarrows() throws {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 900, height: 500))
        for name in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            _ = controller.model.openTab(profile: TestApp.profile(name, "sleep 30"))
        }
        let content = try XCTUnwrap(window.contentView)
        func strip() -> NSScrollView? { content.layoutSubtreeIfNeeded(); return tabStrip(in: content) }
        func lastTabVisible() -> Bool {
            guard let s = strip(), let document = s.documentView else { return false }
            return s.contentView.bounds.maxX >= document.frame.width - 0.5
        }
        TestApp.pump(until: lastTabVisible)
        XCTAssertTrue(lastTabVisible(), "the new (last) tab is scrolled into view")

        window.setContentSize(NSSize(width: 620, height: 500))
        TestApp.pump(until: lastTabVisible, timeout: 2)
        XCTAssertTrue(lastTabVisible(), "still whole after the window narrows")
    }
}
#endif
