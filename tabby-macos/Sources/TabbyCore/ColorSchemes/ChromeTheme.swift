import Foundation

/// UI chrome colours derived from the active terminal colour scheme, so the window always
/// matches the terminal (the idea of Tabby's `ThemesService.applyThemeVariables`). The token
/// set and its derivation follow the phase 2 design: see `docs/DESIGN-TOKENS.md`. Colours are
/// mixed in OKLab like the design's CSS `color-mix(in oklab, …)`.
public struct ChromeTheme: Hashable, Sendable {
    public var isDark: Bool
    /// Window, terminal and active tab (scheme background).
    public var surface: RGBColor
    /// Tab bar and sidebars: the background mixed 8% towards black.
    public var surfaceChrome: RGBColor
    /// Popovers, sheets and menus: the background mixed 10% towards white.
    public var surfaceRaised: RGBColor
    /// Hover and control wells (foreground at 8%).
    public var fill: RGBColor
    /// Pressed states, keycaps and buttons (foreground at 14%).
    public var fillStrong: RGBColor
    /// Hairlines and outlines (foreground at 16%).
    public var border: RGBColor
    /// List rows and pane dividers (foreground at 10%).
    public var separator: RGBColor
    public var text: RGBColor
    /// Secondary text and inactive tabs: 64% foreground over the background.
    public var textMuted: RGBColor
    /// Tab index and placeholders: 42% foreground over the background.
    public var textFaint: RGBColor
    /// ANSI 4: selection, focus, default button.
    public var accent: RGBColor
    /// Accent at 20%: progress, drop zones, toggles that are on.
    public var accentFill: RGBColor
    /// Black or white, whichever reads better on the accent.
    public var onAccent: RGBColor
    public var danger: RGBColor
    public var success: RGBColor
    public var warning: RGBColor

    /// What the window, tab bar and active tab actually paint: the tokens above, made
    /// translucent when vibrancy is on (68%, 45% and 70% in the design).
    public var windowBackground: RGBColor
    public var chromeBackground: RGBColor
    public var activeTab: RGBColor

    public init(scheme: ColorScheme, vibrancy: Bool = false, minimumContrastRatio: Double = 4) {
        let fg = scheme.foregroundRGB
        let bg = scheme.backgroundRGB
        let palette = scheme.paletteRGB
        func color(_ i: Int) -> RGBColor { i < palette.count ? palette[i] : fg }
        isDark = bg.luminance < fg.luminance

        surface = bg
        surfaceChrome = bg.mixOKLab(.black, 0.08)
        surfaceRaised = bg.mixOKLab(.white, 0.10)
        fill = fg.withAlpha(0.08)
        fillStrong = fg.withAlpha(0.14)
        border = fg.withAlpha(0.16)
        separator = fg.withAlpha(0.10)
        text = fg.ensuringContrast(minimumContrastRatio, against: bg)
        textMuted = fg.mixOKLab(bg, 0.36).ensuringContrast(min(3, minimumContrastRatio), against: bg)
        textFaint = fg.mixOKLab(bg, 0.58)
        accent = color(4)
        accentFill = color(4).withAlpha(0.2)
        onAccent = color(4).contrast(with: .white) > color(4).contrast(with: .black) ? .white : .black
        danger = color(1)
        success = color(2)
        warning = color(3)

        windowBackground = vibrancy ? surface.withAlpha(0.68) : surface
        chromeBackground = vibrancy ? surfaceChrome.withAlpha(0.45) : surfaceChrome
        activeTab = vibrancy ? surface.withAlpha(0.70) : surface
    }
}
