#if canImport(AppKit)
import Foundation

/// Widths for a horizontal tab strip (the design's tab board). Fixed tabs are 176 pt and shrink
/// to 120 pt before the strip scrolls; flex tabs (`appearance.flexTabs`) share the strip down
/// to 64 pt; pinned tabs are 92 pt. When the tabs do not fit, the strip scrolls and gives up
/// room for the "+N" menu of tabs that are out of view.
struct TabStripLayout: Equatable {
    static let gap = 2.0
    static let pinned = 92.0
    static let fixed = 176.0
    static let fixedMinimum = 120.0
    static let flexMinimum = 64.0
    static let overflowButton = 44.0

    /// Width of each unpinned tab.
    var regularWidth: Double
    var pinnedWidth: Double { Self.pinned }
    /// Width of all tabs and gaps together.
    var contentWidth: Double
    /// Width the strip takes in the bar; less than `contentWidth` when it scrolls.
    var stripWidth: Double
    var overflows: Bool

    init(available: Double, pinned: Int, regular: Int, flex: Bool) {
        let count = pinned + regular
        let gaps = Double(max(0, count - 1)) * Self.gap
        let pinnedTotal = Double(pinned) * Self.pinned

        func width(in space: Double) -> Double {
            guard regular > 0 else { return 0 }
            let share = (space - pinnedTotal - gaps) / Double(regular)
            return flex ? max(Self.flexMinimum, share) : min(Self.fixed, max(Self.fixedMinimum, share))
        }
        func content(_ w: Double) -> Double { pinnedTotal + Double(regular) * w + gaps }

        let space = max(0, available)
        var w = width(in: space)
        overflows = content(w) > space + 0.5
        if overflows {
            w = width(in: space - Self.overflowButton)
            stripWidth = max(0, space - Self.overflowButton)
        } else {
            stripWidth = content(w)
        }
        regularWidth = w
        contentWidth = content(w)
    }

    /// Indices of tabs whose frame is not fully inside the visible part of the strip.
    static func hiddenIndices(frames: [ClosedRange<Double>], viewport: ClosedRange<Double>) -> [Int] {
        frames.indices.filter { i in
            frames[i].lowerBound < viewport.lowerBound - 0.5 || frames[i].upperBound > viewport.upperBound + 0.5
        }
    }
}
#endif
