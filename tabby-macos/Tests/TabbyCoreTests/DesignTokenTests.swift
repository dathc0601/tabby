import XCTest
@testable import TabbyCore

/// The phase 2 design tokens (`docs/DESIGN-TOKENS.md`): OKLab mixing, the colour tokens
/// derived from a terminal scheme, and the sizes that scale with spaciness.
final class DesignTokenTests: XCTestCase {
    // MARK: OKLab

    func testOKLabMidpointOfBlackAndWhite() {
        // CSS `color-mix(in oklab, black, white)` is rgb(99 99 99), not the sRGB midpoint.
        XCTAssertEqual(RGBColor.black.mixOKLab(.white, 0.5).hex, "#636363")
    }

    func testOKLabRoundTrip() {
        for hex in ["#5da9f6", "#ff615a", "#171717", "#ffffff", "#000000", "#eab700"] {
            let c = RGBColor(hex: hex)!
            let back = RGBColor(oklab: c.oklab, alpha: c.a)
            XCTAssertEqual(back.r, c.r, accuracy: 1e-6, hex)
            XCTAssertEqual(back.g, c.g, accuracy: 1e-6, hex)
            XCTAssertEqual(back.b, c.b, accuracy: 1e-6, hex)
        }
    }

    func testOKLabMixEnds() {
        let a = RGBColor(hex: "#5da9f6")!, b = RGBColor(hex: "#171717")!
        XCTAssertEqual(a.mixOKLab(b, 0).hex, a.hex)
        XCTAssertEqual(a.mixOKLab(b, 1).hex, b.hex)
    }

    // MARK: Colour tokens

    func testDarkSchemeTokens() {
        let t = ChromeTheme(scheme: .tabbyDefault)
        XCTAssertTrue(t.isDark)
        XCTAssertEqual(t.surface.hex, "#171717")
        XCTAssertEqual(t.surfaceChrome.hex, RGBColor(hex: "#171717")!.mixOKLab(.black, 0.08).hex)
        XCTAssertEqual(t.surfaceRaised.hex, RGBColor(hex: "#171717")!.mixOKLab(.white, 0.10).hex)
        XCTAssertLessThan(t.surfaceChrome.luminance, t.surface.luminance)
        XCTAssertGreaterThan(t.surfaceRaised.luminance, t.surface.luminance)
        XCTAssertEqual(t.fill.hex, "#cacaca14", "fg at 8% alpha")
        XCTAssertEqual(t.fillStrong.a, 0.14, accuracy: 1e-9)
        XCTAssertEqual(t.border.a, 0.16, accuracy: 1e-9)
        XCTAssertEqual(t.separator.a, 0.10, accuracy: 1e-9)
        XCTAssertEqual(t.text.hex, "#cacaca")
        XCTAssertEqual(t.textMuted.hex, RGBColor(hex: "#cacaca")!.mixOKLab(RGBColor(hex: "#171717")!, 0.36).hex)
        XCTAssertEqual(t.textFaint.hex, RGBColor(hex: "#cacaca")!.mixOKLab(RGBColor(hex: "#171717")!, 0.58).hex)
        XCTAssertEqual(t.accent.hex, "#5da9f6")
        XCTAssertEqual(t.accentFill.hex, "#5da9f633", "accent at 20% alpha")
        XCTAssertEqual(t.onAccent, .black, "black reads better than white on #5da9f6")
        XCTAssertEqual(t.danger.hex, "#ff615a")
        XCTAssertEqual(t.success.hex, "#b1e969")
        XCTAssertEqual(t.warning.hex, "#ebd99c")
    }

    func testLightSchemeTokens() {
        let t = ChromeTheme(scheme: .tabbyDefaultLight)
        XCTAssertFalse(t.isDark)
        XCTAssertEqual(t.danger.hex, "#c82829")
        XCTAssertEqual(t.accent.hex, "#4271ae")
        XCTAssertEqual(t.onAccent, .white)
        XCTAssertLessThan(t.surfaceChrome.luminance, t.surface.luminance, "chrome is darker on light schemes too")
    }

    func testTextKeepsTheMinimumContrast() {
        let low = ColorScheme(name: "Low", foreground: "#555555", background: "#333333", cursor: "#555555",
                              colors: ColorScheme.tabbyDefault.colors)
        let t = ChromeTheme(scheme: low, minimumContrastRatio: 4.5)
        XCTAssertGreaterThanOrEqual(t.text.contrast(with: t.surface), 4.5)
        XCTAssertGreaterThanOrEqual(t.textMuted.contrast(with: t.surface), 3)
    }

    func testVibrancyMakesSurfacesTranslucent() {
        let t = ChromeTheme(scheme: .tabbyDefault, vibrancy: true)
        XCTAssertEqual(t.windowBackground.a, 0.68, accuracy: 1e-9)
        XCTAssertEqual(t.chromeBackground.a, 0.45, accuracy: 1e-9)
        XCTAssertEqual(t.activeTab.a, 0.70, accuracy: 1e-9)
        XCTAssertEqual(t.surface.a, 1, "the token itself stays opaque")
        let opaque = ChromeTheme(scheme: .tabbyDefault)
        XCTAssertEqual(opaque.windowBackground, opaque.surface)
        XCTAssertEqual(opaque.chromeBackground, opaque.surfaceChrome)
        XCTAssertEqual(opaque.activeTab, opaque.surface)
    }

    // MARK: Metrics

    func testMetricsScaleWithSpaciness() {
        let small = ChromeMetrics(spaciness: 0.8), normal = ChromeMetrics(spaciness: 1), large = ChromeMetrics(spaciness: 1.5)
        XCTAssertEqual(small.tabBar, 30.4, accuracy: 1e-9)
        XCTAssertEqual(normal.tabBar, 38)
        XCTAssertEqual(large.tabBar, 57)
        XCTAssertEqual(normal.tab, 28)
        XCTAssertEqual(large.tab, 42)
        XCTAssertEqual(normal.formRow, 40)
        XCTAssertEqual(normal.formRowTall, 52)
        XCTAssertEqual(normal.selectorRow, 34)
        XCTAssertEqual(large.selectorRow, 51)
        XCTAssertEqual(normal.space(12), 12)
        XCTAssertEqual(large.space(8), 12)
    }

    func testMetricsIgnoreNonsenseSpaciness() {
        XCTAssertEqual(ChromeMetrics(spaciness: 0).tabBar, 38, "0 or negative falls back to 1")
        XCTAssertEqual(ChromeMetrics(spaciness: .nan).tabBar, 38)
    }
}
