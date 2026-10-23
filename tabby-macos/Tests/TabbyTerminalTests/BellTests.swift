import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 5: Tabby's bell (`BaseTerminalTabComponent`: a bell marks an unfocused tab active;
/// `terminal.bellFlashFrame` flashes the window).
final class BellTests: XCTestCase {
    func testTheFlashSettingIsRead() throws {
        let defaults = try ConfigStore.bundledDefaults()
        XCTAssertFalse(TerminalSettings(config: ConfigStore(defaults: defaults)).bellFlashFrame)
        let on = ConfigStore(defaults: defaults, user: ["terminal": ["bellFlashFrame": true]])
        XCTAssertTrue(TerminalSettings(config: on).bellFlashFrame)
    }

    func testABellMarksAnUnfocusedPaneActive() throws {
        let (pane, engine, _) = try makeFakePane(type: "local")
        defer { pane.close() }
        var bells = 0
        pane.onBell = { _ in bells += 1 }
        pane.isFocused = true
        pane.engineBell(engine)
        XCTAssertFalse(pane.hasActivity, "the pane in front")
        XCTAssertEqual(bells, 1)
        pane.isFocused = false
        pane.engineBell(engine)
        XCTAssertTrue(pane.hasActivity)
        XCTAssertEqual(bells, 2)
    }
}
