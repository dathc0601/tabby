import Foundation

/// UI chrome colours derived from the active terminal colour scheme. Port of
/// `ThemesService.applyThemeVariables` (`tabby-core/src/services/themes.service.ts`), which is
/// why Tabby's window always matches the terminal.
///
/// These semantic tokens are what views use; a redesign only has to change this mapping.
public struct ChromeTheme: Hashable, Sendable {
    public var isDark: Bool
    /// Window background (`--body-bg`), faded when vibrancy is on.
    public var windowBackground: RGBColor
    /// Terminal / content background (`--theme-bg`).
    public var surface: RGBColor
    /// Raised surfaces: active tab, popovers (`--theme-bg-more`).
    public var surfaceRaised: RGBColor
    public var surfaceRaised2: RGBColor
    /// Recessed surfaces: tab bar, inactive tabs (`--theme-bg-less`).
    public var surfaceSunken: RGBColor
    public var text: RGBColor
    public var textMuted: RGBColor
    public var textFaint: RGBColor
    public var border: RGBColor
    public var accent: RGBColor
    public var accentText: RGBColor
    public var danger: RGBColor
    public var success: RGBColor
    public var warning: RGBColor
    public var info: RGBColor

    public init(scheme: ColorScheme, vibrancy: Bool = false, minimumContrastRatio: Double = 4) {
        let fg = scheme.foregroundRGB
        let bg = scheme.backgroundRGB
        let palette = scheme.paletteRGB
        let dark = bg.luminance < fg.luminance
        isDark = dark

        func more(_ c: RGBColor, _ f: Double) -> RGBColor { dark ? c.darken(f) : c.lighten(f) }
        func less(_ c: RGBColor, _ f: Double) -> RGBColor { dark ? c.lighten(f) : c.darken(f) }
        func color(_ i: Int) -> RGBColor { i < palette.count ? palette[i] : fg }

        windowBackground = vibrancy ? bg.fade(0.6) : bg
        surface = bg
        surfaceRaised = more(bg, 0.25)
        surfaceRaised2 = more(surfaceRaised, 0.25)
        surfaceSunken = less(bg, 0.25)
        text = fg.ensuringContrast(minimumContrastRatio, against: bg)
        textMuted = less(fg, 0.25).mix(bg, 0.35).ensuringContrast(min(3, minimumContrastRatio), against: bg)
        textFaint = fg.mix(bg, 0.6)
        border = fg.mix(bg, 0.85)
        accent = color(4)
        accentText = color(4).contrast(with: .white) >= color(4).contrast(with: .black) ? .white : .black
        danger = color(1)
        success = color(2)
        warning = color(3)
        info = color(4)
    }
}
