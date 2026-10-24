import XCTest
@testable import TabbyCore

/// Phase 7: Tabby's per-profile, per-type, per-group and per-settings-page hotkeys
/// (`tabby-core/src/hotkeys.ts`, `tabby-settings/src/hotkeys.ts`).
final class DynamicHotkeyTests: XCTestCase {
    func testDynamicEntriesUseTabbysIdsAndWords() {
        let profile = Profile(config: ["id": "local:custom:a.b:1", "name": "A", "type": "local", "options": [:]])
        let entries = HotkeyCatalog.dynamicEntries(profiles: [profile], types: [(id: "ssh", name: "SSH connection")],
                                                   groups: [ProfileGroup(id: "G", name: "Work")],
                                                   settingsPages: [(id: "terminal", title: "Terminal")])
        XCTAssertEqual(entries.map(\.id), ["profile.local:custom:a-b:1", "profile-selectors.ssh", "group-selectors.G", "settings-tab.terminal"])
        XCTAssertEqual(entries.map(\.name), ["New tab: A", "Show SSH connection profile selector",
                                             "Show profile selector for group Work", "Open settings tab: Terminal"])
        XCTAssertEqual(entries.map(\.group), ["Profiles", "Profiles", "Profiles", "Application"])
    }

    func testProfileRowsUseTabbysHotkeyName() {
        let profile = Profile(config: ["id": "ssh:custom:x.y.z:9", "name": "xyz", "type": "ssh", "options": [:]])
        XCTAssertEqual(HotkeyCatalog.dynamicEntries(profiles: [profile], types: [], groups: [], settingsPages: []).first?.id,
                       profile.hotkeyId)
        XCTAssertEqual(profile.hotkeyId, "profile.ssh:custom:x-y-z:9")
    }
}
