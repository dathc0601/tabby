#if canImport(AppKit)
import SwiftUI
import TabbyCore

private struct ChromeKey: EnvironmentKey {
    static let defaultValue = ChromeTheme(scheme: .tabbyDefault)
}

private struct MetricsKey: EnvironmentKey {
    static let defaultValue = ChromeMetrics(spaciness: 1)
}

extension EnvironmentValues {
    /// The colour tokens of the active scheme (`docs/DESIGN-TOKENS.md`).
    var chrome: ChromeTheme {
        get { self[ChromeKey.self] }
        set { self[ChromeKey.self] = newValue }
    }

    /// Sizes scaled by `appearance.spaciness`.
    var metrics: ChromeMetrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

/// Feeds the live theme into the environment. Reading `ThemeManager` here registers the
/// observation, so everything below re-renders when the scheme, vibrancy or spaciness change.
private struct ChromeEnvironmentModifier: ViewModifier {
    func body(content: Content) -> some View {
        let theme = AppServices.shared.theme
        content
            .environment(\.chrome, theme.chrome)
            .environment(\.metrics, theme.metrics)
    }
}

extension View {
    /// Apply once at the root of every SwiftUI hierarchy hosted in AppKit. Root views apply it
    /// inside their own `body` so their `NSHostingView<RootView>` type stays recognisable.
    func chromeEnvironment() -> some View { modifier(ChromeEnvironmentModifier()) }
}

/// The design's type scale.
enum ChromeFont {
    static let largeTitle = Font.system(size: 26, weight: .semibold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let bodyEmphasised = Font.system(size: 13, weight: .medium)
    static let callout = Font.system(size: 12.5)
    static let caption = Font.system(size: 12)
    static let groupHeader = Font.system(size: 11, weight: .semibold)
    static let monoUI = Font.custom("Menlo", size: 12)
    static let tabIndex = Font.custom("Menlo", size: 10.5)
}
#endif
