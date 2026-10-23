import XCTest
@testable import TabbyCore

final class HotkeyTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(Keystroke("⌘-Shift-D")?.description, "⌘-Shift-D")
        XCTAssertEqual(Keystroke("Shift-⌘-d")?.description, "⌘-Shift-D", "modifier order is canonical")
        XCTAssertEqual(Keystroke("Ctrl+⌘+F")?.description, "Ctrl-⌘-F", "+ separators are accepted")
        XCTAssertEqual(Keystroke("⌘--")?.key, "-")
        XCTAssertEqual(Keystroke("⌘-Shift--")?.description, "⌘-Shift--")
        XCTAssertEqual(Keystroke("⌘-=")?.key, "=")
        XCTAssertEqual(Keystroke("⌥-Left")?.modifiers, [.option])
        XCTAssertEqual(Keystroke("Cmd-Alt-Enter")?.description, "⌘-⌥-Enter")
        XCTAssertEqual(Keystroke("Ctrl-Shift")?.isModifierOnly, true)
        XCTAssertEqual(Keystroke("Ctrl-Shift")?.modifiers, [.control, .shift])
        XCTAssertEqual(Keystroke("Home")?.key, "Home")
        XCTAssertEqual(Keystroke("⌘-,")?.key, ",")
        XCTAssertNil(Keystroke(""))
        XCTAssertEqual(Keystroke("⌘-Shift-D")?.symbolicDescription, "⇧⌘D")
    }

    func testEveryDefaultBindingParses() throws {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        guard let hotkeys = store.value("hotkeys")?.objectValue else { return XCTFail("no hotkeys") }
        for (id, value) in hotkeys {
            for raw in value.stringArrayValue ?? [] {
                let k = Keystroke(raw)
                XCTAssertNotNil(k, "\(id): \(raw)")
                if let k, !raw.contains("+") {
                    XCTAssertEqual(Keystroke(k.description), k, "\(id): \(raw) round-trips")
                }
            }
        }
        let map = HotkeyMatcher.bindings(fromHotkeysConfig: store.value("hotkeys"))
        XCTAssertEqual(map["split-right"], [HotkeyBinding("⌘-Shift-D")!])
        XCTAssertNil(map["split-left"], "empty bindings are dropped")
    }

    func testChordBindingsFromConfig() throws {
        let value: ConfigValue = ["⌘-W", ["Ctrl-A", "C"]]
        let b = HotkeyBinding.bindings(from: value)
        XCTAssertEqual(b.count, 2)
        XCTAssertEqual(b[1].strokes.map(\.description), ["Ctrl-A", "C"])
        XCTAssertEqual(HotkeyBinding.configValue(for: b), value)
    }

    func testMatcher() {
        let m = HotkeyMatcher(bindings: [
            "close-tab": [HotkeyBinding("⌘-W")!],
            "chord": [HotkeyBinding([Keystroke("Ctrl-A")!, Keystroke("C")!])],
            "zoom-in": [HotkeyBinding("⌘-=")!, HotkeyBinding("⌘-Shift-=")!],
        ])
        XCTAssertEqual(m.feed(Keystroke("⌘-W")!, at: 0), .matched("close-tab"))
        XCTAssertEqual(m.feed(Keystroke("X")!, at: 1), .none)
        XCTAssertEqual(m.feed(Keystroke("Ctrl-A")!, at: 2), .partial)
        XCTAssertEqual(m.feed(Keystroke("C")!, at: 2.5), .matched("chord"))
        XCTAssertEqual(m.feed(Keystroke("C")!, at: 2.6), .none, "history cleared after a chord")
        XCTAssertEqual(m.feed(Keystroke("Ctrl-A")!, at: 10), .partial)
        XCTAssertEqual(m.feed(Keystroke("C")!, at: 13), .none, "chord times out")
        XCTAssertEqual(m.feed(Keystroke("⌘-Shift-=")!, at: 20), .matched("zoom-in"))
        XCTAssertEqual(m.feed(Keystroke("Ctrl-Shift")!, at: 21), .none, "modifier-only strokes are ignored")
    }
}
