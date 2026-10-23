#if canImport(AppKit)
import TabbyCore

/// SwiftUI also declares `ColorScheme`; inside TabbyApp the name means the terminal scheme.
typealias ColorScheme = TabbyCore.ColorScheme
/// The macOS 27 SDK also has an `RGBColor`; inside TabbyApp the name means TabbyCore's.
typealias RGBColor = TabbyCore.RGBColor
#endif
