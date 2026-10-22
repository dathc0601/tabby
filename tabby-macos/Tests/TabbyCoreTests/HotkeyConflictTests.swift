import XCTest
@testable import TabbyCore

/// The capture sheet warns when a new binding is already used ("Also used by …"), including
/// when one binding is the first part of the other's chord.
final class HotkeyConflictTests: XCTestCase {
    func testSameBindingConflicts() throws {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        let newTab = try XCTUnwrap(HotkeyBinding.bindings(from: store.value("hotkeys.new-tab")).first)
        XCTAssertEqual(HotkeyCatalog.conflicts(with: newTab, excluding: "split-right", config: store).map(\.id), ["new-tab"])
        XCTAssertEqual(HotkeyCatalog.conflicts(with: newTab, excluding: "new-tab", config: store), [])
    }

    func testChordPrefixConflicts() throws {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        store.set("hotkeys.clear", .array([.array(["⌘-K", "⌘-S"])]))
        let prefix = try XCTUnwrap(HotkeyBinding("⌘-K"))
        XCTAssertTrue(HotkeyCatalog.conflicts(with: prefix, excluding: "settings", config: store).map(\.id).contains("clear"))
        let unrelated = HotkeyBinding([try XCTUnwrap(Keystroke("⌘-K")), try XCTUnwrap(Keystroke("⌘-X"))])
        XCTAssertFalse(HotkeyCatalog.conflicts(with: unrelated, excluding: "settings", config: store).map(\.id).contains("clear"))
    }
}
