import Foundation

/// Sizes from the design that scale with `appearance.spaciness` (0.8–1.5 in Settings).
public struct ChromeMetrics: Hashable, Sendable {
    public var spaciness: Double

    public init(spaciness: Double) {
        self.spaciness = spaciness.isFinite && spaciness > 0 ? spaciness : 1
    }

    public var tabBar: Double { 38 * spaciness }
    public var tab: Double { 28 * spaciness }
    public var formRow: Double { 40 * spaciness }
    public var formRowTall: Double { 52 * spaciness }
    public var selectorRow: Double { 34 * spaciness }
    /// Space around the terminal inside its pane: Tabby's `baseTerminalTab` `.content` margin,
    /// `max(0px, 30px * var(--spaciness) - 15px)` (15 at the default spaciness).
    public var terminalMargin: Double { max(0, 30 * spaciness - 15) }
    /// The `sp-N` spacing scale (2, 4, 6, 8, 12, 16, 20, 24) × spaciness.
    public func space(_ points: Double) -> Double { points * spaciness }
}
