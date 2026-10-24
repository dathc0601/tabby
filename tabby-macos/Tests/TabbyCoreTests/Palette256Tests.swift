import XCTest
@testable import TabbyCore

/// Phase 7: Tabby's 256-colour palette (`generatePalette.ts`) and custom schemes. The expected
/// values come from running Tabby's own generatePalette.ts with Node.
final class Palette256Tests: XCTestCase {
    let picks = [16, 21, 196, 231, 232, 255]
    func pick(_ p: [String]) -> [String] { picks.map { p[$0 - 16] } }

    func testMatchesTabbysGenerator() {
        let s = ColorScheme.tabbyDefault
        let p = Palette256.generate(colors: s.colors, background: s.background, foreground: s.foreground, harmonious: false)
        XCTAssertEqual(p.count, 240)
        XCTAssertEqual(pick(p), ["#171717", "#5da9f6", "#ff615a", "#cacaca", "#1d1d1d", "#c2c2c2"])
    }

    func testHarmoniousKeepsLightOrder() {
        let s = ColorScheme.tabbyDefaultLight
        XCTAssertEqual(pick(Palette256.generate(colors: s.colors, background: s.background, foreground: s.foreground, harmonious: false)),
                       ["#4d4d4c", "#4271ae", "#c82829", "#ffffff", "#535352", "#f7f7f7"])
        XCTAssertEqual(pick(Palette256.generate(colors: s.colors, background: s.background, foreground: s.foreground, harmonious: true)),
                       ["#ffffff", "#4271ae", "#c82829", "#4d4d4c", "#f7f7f7", "#535352"])
    }

    func testUserColoursBeyondSixteenAreKept() {
        let s = ColorScheme.tabbyDefault
        let p = Palette256.generate(colors: s.colors + ["#123456"], background: s.background, foreground: s.foreground, harmonious: false)
        XCTAssertEqual(p[0], "#123456")
    }

    func testHTMLUsesTheGeneratedPalette() {
        let s = ColorScheme.tabbyDefault
        var cell = StyledCell(text: "x")
        cell.foreground = .ansi(21)
        let plain = TerminalHTML.render(lines: [[cell]], scheme: s, fontFamily: "Menlo", brightBold: true)
        XCTAssertTrue(plain.contains("#0000ff"), "the xterm cube without generation")
        let extended = Palette256.generate(colors: s.colors, background: s.background, foreground: s.foreground, harmonious: false)
        let generated = TerminalHTML.render(lines: [[cell]], scheme: s, fontFamily: "Menlo", brightBold: true, extended: extended)
        XCTAssertTrue(generated.contains("#5da9f6"), generated)
    }

    func store(_ user: ConfigValue) throws -> ConfigStore { ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: user) }

    func testRenameAndDeleteCustomScheme() throws {
        var mine = ColorScheme.tabbyDefault
        mine.name = "Mine"
        var other = ColorScheme.tabbyDefault
        other.name = "Other"
        let c = try store(["terminal": ["customColorSchemes": [mine.configValue, other.configValue], "colorScheme": mine.configValue]])
        ColorSchemeCatalog.renameCustom("Mine", to: "Ours", in: c)
        XCTAssertEqual(ColorSchemeCatalog.customSchemes(from: c).map(\.name), ["Ours", "Other"])
        XCTAssertEqual(c.value("terminal.colorScheme.name")?.stringValue, "Ours", "the selection follows the rename")
        ColorSchemeCatalog.deleteCustom("Other", in: c)
        XCTAssertEqual(ColorSchemeCatalog.customSchemes(from: c).map(\.name), ["Ours"])
        XCTAssertFalse(ColorSchemeCatalog.renameCustom("Ours", to: "", in: c), "an empty name is refused")
    }
}
