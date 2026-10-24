#if canImport(AppKit)
import XCTest
import AppKit
import SwiftTerm
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 7: line padding and the 256-colour palette on the real SwiftTerm view.
final class EngineAppearanceTests: XCTestCase {
    func engine(_ terminal: [String: ConfigValue]) throws -> SwiftTermEngine {
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: .object(["terminal": .object(terminal)]))
        let settings = TerminalSettings(config: config)
        let engine = SwiftTermEngine(frame: CGRect(x: 0, y: 0, width: 600, height: 200), settings: settings)
        engine.apply(settings: settings, scheme: .tabbyDefault, fontSize: settings.fontSize)
        return engine
    }

    func testSettingsDefaults() throws {
        let s = TerminalSettings(config: ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: .emptyObject))
        XCTAssertEqual(s.linePadding, 0)
        XCTAssertFalse(s.paletteGenerate)
        XCTAssertFalse(s.paletteHarmonious)
    }

    func testLinePaddingSetsLineSpacing() throws {
        XCTAssertEqual(SwiftTermEngine.lineSpacing(fontSize: 14, padding: 2), 18.0 / 14.0, accuracy: 0.0001)
        XCTAssertEqual(SwiftTermEngine.lineSpacing(fontSize: 14, padding: -3), 1, "never below one line")
        let e = try engine(["fontSize": 14, "linePadding": 2])
        XCTAssertEqual(e.lineSpacing, 18.0 / 14.0, accuracy: 0.0001)
    }

    func testCursorAccentAndSelectionForegroundReachTheView() throws {
        func hex(_ c: NSColor?) -> String? {
            guard let c = c?.usingColorSpace(.sRGB) else { return nil }
            return RGBColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).hex
        }
        let e = try engine([:])
        var scheme = ColorScheme.tabbyDefault
        scheme.cursorAccent = "#ff0000"
        scheme.selectionForeground = "#00ff00"
        e.apply(settings: TerminalSettings(config: ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: .emptyObject)), scheme: scheme, fontSize: 14)
        XCTAssertEqual(hex(e.caretTextColor), "#ff0000")
        XCTAssertEqual(hex(e.selectedTextForegroundColor), "#00ff00")
        let plain = try engine([:])
        XCTAssertEqual(hex(plain.selectedTextForegroundColor), ColorScheme.tabbyDefault.foreground,
                       "without one, the scheme's foreground (SwiftTerm would draw selected text black)")
        XCTAssertNil(plain.caretTextColor)
    }

    func testPaletteSettingPicksTheStrategy() throws {
        XCTAssertEqual(try engine([:]).getTerminal().options.ansi256PaletteStrategy, .xterm, "Tabby's default: the xterm cube")
        XCTAssertEqual(try engine(["paletteGenerate": true]).getTerminal().options.ansi256PaletteStrategy, .base16Lab)
        XCTAssertEqual(try engine(["paletteGenerate": true, "paletteHarmonious": true]).getTerminal().options.ansi256PaletteStrategy,
                       .base16LabHarmonious)
    }
}
#endif
