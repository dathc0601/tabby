import XCTest
@testable import TabbyCore

final class RecoveryTests: XCTestCase {
    func testTabbyTokenDecodes() throws {
        // Shape written by Tabby's TabRecoveryService for a tab with two panes.
        let json = """
        [{"type":"app:split-tab","orientation":"h","ratios":[0.3,0.7],"tabPinned":true,"tabColor":"#ff0000",
          "children":[
            {"type":"app:local-tab","profile":{"type":"local","name":"zsh","options":{"command":"/bin/zsh","cwd":"/tmp"}},"tabTitle":"zsh"},
            {"type":"app:ssh-tab","profile":{"type":"ssh","name":"box","options":{"host":"box"}},"savedState":"hello"}
          ]}]
        """
        let value = try JSONDecoder().decode(ConfigValue.self, from: Data(json.utf8))
        let tokens = value.arrayValue!.compactMap(RecoveryToken.init)
        XCTAssertEqual(tokens.count, 1)
        let panes = tokens[0].panes
        XCTAssertEqual(panes.map(\.profile.type), ["local", "ssh"])
        XCTAssertEqual(panes[0].cwd, "/tmp")
        XCTAssertEqual(panes[1].savedState, "hello")
        let (layout, map) = tokens[0].makeLayout()
        XCTAssertEqual(layout.panes.count, 2)
        XCTAssertEqual(layout.root.ratios[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(map[layout.panes[1]]?.profile.name, "box")
        guard case let .split(_, _, _, pinned, _, color) = tokens[0] else { return XCTFail() }
        XCTAssertTrue(pinned)
        XCTAssertEqual(color, "#ff0000")
    }

    func testRoundTripThroughStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecoveryStore(url: dir.appendingPathComponent("recovery.json"))
        var layout = SplitLayout(single: UUID())
        let second = UUID()
        layout.insert(second, relativeTo: layout.panes[0], side: .bottom)
        let token = RecoveryToken.from(layout: layout, customTitle: "work") { id in
            PaneRecovery(type: "app:local-tab", profile: Profile(type: "local", name: id == second ? "two" : "one"))
        }!
        try store.save([token])
        let loaded = store.load()
        XCTAssertEqual(loaded, [token])
        XCTAssertEqual(loaded[0].panes.map(\.profile.name), ["one", "two"])
    }
}

final class ColorSchemeTests: XCTestCase {
    func testAllBundledSchemesParse() {
        let schemes = ColorSchemeCatalog.loadBundledSchemes()
        XCTAssertGreaterThanOrEqual(schemes.count, 185, "most of the 191 community schemes should parse")
        for s in schemes {
            XCTAssertEqual(s.colors.count, 16, s.name)
            XCTAssertNotNil(RGBColor(hex: s.background), "\(s.name) background \(s.background)")
            XCTAssertNotNil(RGBColor(hex: s.foreground), "\(s.name) foreground \(s.foreground)")
        }
        let dracula = schemes.first { $0.name == "Dracula" }
        XCTAssertEqual(dracula?.background, "#1e1f29")
        XCTAssertEqual(dracula?.colors[4], "#bd93f9")
    }

    func testDefineVariables() {
        let text = "#define base00 #002b36\n#define base05 #839496\n*.foreground: base05\n*.background: base00\n"
            + (0..<16).map { "*.color\($0): #0000\(String(format: "%02x", $0))" }.joined(separator: "\n")
        let s = XresourcesParser.parse(name: "Test ", text: text)
        XCTAssertEqual(s?.name, "Test")
        XCTAssertEqual(s?.foreground, "#839496")
        XCTAssertEqual(s?.background, "#002b36")
        XCTAssertEqual(s?.cursor, "#839496", "cursor falls back to foreground")
    }

    func testActiveSchemeFollowsMode() throws {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        XCTAssertEqual(ColorSchemeCatalog.activeScheme(config: store, systemIsDark: false).name, "Tabby Default")
        store.set("appearance.colorSchemeMode", "auto")
        XCTAssertEqual(ColorSchemeCatalog.activeScheme(config: store, systemIsDark: false).name, "Tabby Default Light")
        XCTAssertEqual(ColorSchemeCatalog.activeScheme(config: store, systemIsDark: true).name, "Tabby Default")
        store.set("appearance.colorSchemeMode", "light")
        XCTAssertEqual(ColorSchemeCatalog.activeScheme(config: store, systemIsDark: true).name, "Tabby Default Light")
    }

    func testChromeTheme() {
        let dark = ChromeTheme(scheme: .tabbyDefault)
        XCTAssertTrue(dark.isDark)
        XCTAssertEqual(dark.accent.hex, "#5da9f6")
        XCTAssertGreaterThanOrEqual(dark.text.contrast(with: dark.surface), 4)
        XCTAssertLessThan(dark.surfaceRaised.luminance, dark.surface.luminance + 1e-9, "raised is darker on dark themes")
        let light = ChromeTheme(scheme: .tabbyDefaultLight)
        XCTAssertFalse(light.isDark)
        XCTAssertEqual(light.danger.hex, "#c82829")
        XCTAssertEqual(ChromeTheme(scheme: .tabbyDefault, vibrancy: true).windowBackground.a, 0.4, accuracy: 1e-9)
    }

    func testRGB() {
        XCTAssertEqual(RGBColor(hex: "#abc")?.hex, "#aabbcc")
        XCTAssertEqual(RGBColor(hex: "rgb(255, 0, 0)")?.hex, "#ff0000")
        XCTAssertEqual(RGBColor(hex: "#80808080")?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBColor(hex: "nope"))
        XCTAssertEqual(RGBColor.white.contrast(with: .black), 21, accuracy: 0.01)
        XCTAssertEqual(RGBColor(hex: "#808080")!.darken(0.5).hex, "#404040")
    }
}
