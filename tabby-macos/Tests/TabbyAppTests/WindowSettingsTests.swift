#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: Window › Dock "Display on", the tab options button, the frame picker.
@MainActor
final class WindowSettingsTests: XCTestCase {
    func testDockScreenChoicesStartWithCurrent() {
        let choices = DockScreens.choices()
        XCTAssertEqual(choices.first?.tag, "current")
        XCTAssertEqual(choices.count, NSScreen.screens.count + 1)
    }

    func testDockScreenValuesRoundTrip() {
        XCTAssertEqual(DockScreens.tag(for: .int(5)), "5")
        XCTAssertEqual(DockScreens.tag(for: .string("current")), "current")
        XCTAssertEqual(DockScreens.tag(for: nil), "current")
        XCTAssertEqual(DockScreens.value(for: "5"), .int(5))
        XCTAssertEqual(DockScreens.value(for: "current"), .string("current"))
    }

    func testOptionsButtonHiddenBySetting() {
        XCTAssertTrue(TabBarView.showsOptionsButton(hovering: true, compact: false, hidden: false))
        XCTAssertFalse(TabBarView.showsOptionsButton(hovering: true, compact: false, hidden: true))
        XCTAssertFalse(TabBarView.showsOptionsButton(hovering: false, compact: false, hidden: false))
    }

    func testFullFrameIsReadAsThin() {
        XCTAssertEqual(WindowSettingsView.frameChoice("full"), "thin", "Tabby's Full draws its own buttons; macOS has them")
        XCTAssertEqual(WindowSettingsView.frameChoice("native"), "native")
        XCTAssertEqual(WindowSettingsView.frameChoice(nil), "thin")
    }
}
#endif
