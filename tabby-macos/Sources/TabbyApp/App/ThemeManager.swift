#if canImport(AppKit)
import AppKit
import SwiftUI
import Observation
import TabbyCore

/// The active colour scheme and the chrome palette derived from it (port of Tabby's
/// `ThemesService`). Follows the system appearance when `colorSchemeMode` is `auto`.
@MainActor
@Observable
public final class ThemeManager {
    public private(set) var scheme: TabbyCore.ColorScheme = .tabbyDefault
    public private(set) var chrome: ChromeTheme = ChromeTheme(scheme: .tabbyDefault)
    public private(set) var vibrancy = false
    public private(set) var spaciness: Double = 1
    /// Bumped whenever anything above changes.
    public private(set) var revision = 0

    @ObservationIgnored private weak var config: ConfigStore?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var appliedMode: String?

    init() {
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let config = self.config else { return }
                    self.update(config: config)
                }
            }
        }
    }

    public var systemIsDark: Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    public func update(config: ConfigStore) {
        self.config = config
        let newScheme = ColorSchemeCatalog.activeScheme(config: config, systemIsDark: systemIsDark)
        let vib = config.bool("appearance.vibrancy")
        let contrast = config.double("terminal.minimumContrastRatio") ?? 4
        let newChrome = ChromeTheme(scheme: newScheme, vibrancy: vib, minimumContrastRatio: contrast)
        let newSpaciness = config.double("appearance.spaciness") ?? 1
        if newScheme != scheme || newChrome != chrome || vib != vibrancy || newSpaciness != spaciness {
            scheme = newScheme
            chrome = newChrome
            vibrancy = vib
            spaciness = newSpaciness
            revision += 1
        }
        let mode = config.string("appearance.colorSchemeMode") ?? "dark"
        guard mode != appliedMode else { return }
        appliedMode = mode
        switch mode {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "auto": NSApplication.shared.appearance = nil
        default: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// The scheme for a pane, honouring a per-profile override.
    public func scheme(for profile: Profile) -> TabbyCore.ColorScheme {
        ColorScheme(config: profile.terminalColorScheme) ?? scheme
    }
}

extension TabbyCore.RGBColor {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var color: SwiftUI.Color { SwiftUI.Color(nsColor: nsColor) }
}
#endif
