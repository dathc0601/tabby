#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: the Appearance page's font choices.
@MainActor
final class AppearanceRowsTests: XCTestCase {
    func testFontChoicesListMonospacedFirstThenTheRest() {
        let choices = AppearanceSettingsView.fontChoices(including: "Menlo")
        XCTAssertTrue(choices.monospaced.contains("Menlo"))
        XCTAssertFalse(choices.others.contains("Menlo"))
        XCTAssertTrue(choices.others.contains("Helvetica"), "Tabby lists every font")
        XCTAssertEqual(AppearanceSettingsView.fontChoices(including: "Not A Font").monospaced.first, "Not A Font", "a configured font stays listed")
    }

    func testWeightsGoFrom100To900() {
        XCTAssertEqual(AppearanceSettingsView.weights, [100, 200, 300, 400, 500, 600, 700, 800, 900])
    }
}
#endif
