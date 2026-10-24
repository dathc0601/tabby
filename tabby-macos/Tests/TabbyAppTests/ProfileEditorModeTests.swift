#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: the profile editor's modes and common fields (Tabby's `EditProfileModal`).
@MainActor
final class ProfileEditorModeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func testDefaultsModeTitleAndHiddenFields() {
        XCTAssertEqual(ProfileEditorSheet.title(for: .typeDefaults("ssh")), "Defaults for SSH connection")
        XCTAssertEqual(ProfileEditorSheet.title(for: .groupDefaults(groupId: "G", type: "local")), "Defaults for Local terminal")
        XCTAssertNil(ProfileEditorSheet.title(for: .profile), "a profile shows its own name")
        XCTAssertFalse(ProfileEditorSheet.showsIdentityFields(.typeDefaults("ssh")), "no name, group or icon in defaults")
        XCTAssertTrue(ProfileEditorSheet.showsIdentityFields(.profile))
    }

    func testReconnectOnlyForConnections() {
        XCTAssertFalse(ProfileEditorSheet.sessionEndChoices(for: "local").contains(.reconnect))
        XCTAssertTrue(ProfileEditorSheet.sessionEndChoices(for: "ssh").contains(.reconnect))
        XCTAssertTrue(ProfileEditorSheet.sessionEndChoices(for: "serial").contains(.reconnect))
        XCTAssertTrue(ProfileEditorSheet.sessionEndChoices(for: "telnet").contains(.reconnect))
        XCTAssertEqual(ProfileEditorSheet.sessionEndChoices(for: "local"), [.auto, .keep, .close])
    }

    func testSplitLayoutShowsOnlyCommonFields() {
        XCTAssertEqual(ProfileEditorSheet.pages(for: "split-layout"), [])
        XCTAssertEqual(ProfileEditorSheet.pages(for: "local"), [.general, .advanced, .colors, .scripts])
    }

    func testUnknownIconAndColourRoundTrip() {
        let p = Profile(config: ["id": "x", "type": "ssh", "name": "x", "icon": "fas fa-dragon", "color": "teal", "options": ["host": "h"]])
        let saved = ProfileEditorSheet.finalized(p)
        XCTAssertEqual(saved.icon, "fas fa-dragon")
        XCTAssertEqual(saved.color, "teal")
        XCTAssertEqual(saved.configValue["icon"]?.stringValue, "fas fa-dragon")
    }
}
#endif
