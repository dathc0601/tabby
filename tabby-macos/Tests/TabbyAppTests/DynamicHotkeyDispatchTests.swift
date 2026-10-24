#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: what the dynamic hotkeys do.
@MainActor
final class DynamicHotkeyDispatchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func testSettingsTabHotkeyOpensThePage() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        XCTAssertTrue(c.runCommand("settings-tab.terminal-color-scheme"))
        XCTAssertEqual(c.model.activeTab?.content, .settings)
        XCTAssertEqual(c.model.activeTab?.settingsNavigation?.section, .colorScheme)
        XCTAssertEqual(SettingsSection(tabbyId: "config-sync"), .account)
        XCTAssertNil(SettingsSection(tabbyId: "plugins"))
    }

    func testTypeSelectorHotkeyFiltersByType() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let items = c.profileSelectorItems(type: "local", groupId: nil)
        XCTAssertFalse(items.isEmpty)
        let profiles = AppServices.shared.profiles.selectorEntries(type: "local").compactMap { e -> Profile? in
            if case let .profile(p) = e.kind { return p } else { return nil }
        }
        XCTAssertTrue(profiles.allSatisfy { $0.type == "local" })
        XCTAssertTrue(c.runCommand("profile-selectors.local"))
    }

    func testHotkeysPageListsDynamicRows() {
        let ids = HotkeysSettingsView.allEntries().map(\.id)
        XCTAssertTrue(ids.contains("profile-selectors.ssh"))
        XCTAssertTrue(ids.contains("settings-tab.terminal"))
        XCTAssertTrue(ids.contains("profile.local:default"))
        XCTAssertTrue(ids.contains("new-tab"), "the static rows stay")
    }
}
#endif
