#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Shown over a pane while a tab is dragged onto it: the half the new pane will take, and
/// four 36 pt targets at the edges with the one under the pointer in the accent colour.
@MainActor
final class DropZoneOverlay: NSView {
    /// The half that would be split off; nil highlights the whole pane (dropped files).
    var side: SplitDirection? = .right { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let chrome = AppServices.shared.theme.chrome
        chrome.accentFill.nsColor.setFill()
        let preview = (side?.previewFrame(in: bounds) ?? bounds).insetBy(dx: 3, dy: 3)
        NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8).fill()
        chrome.accent.nsColor.setStroke()
        let outline = NSBezierPath(roundedRect: preview, xRadius: 8, yRadius: 8)
        outline.lineWidth = 1.5
        outline.stroke()
        for target in SplitDirection.allCases {
            let rect = Self.targetFrame(target, in: bounds)
            let active = target == side
            (active ? chrome.accent : chrome.surfaceRaised).nsColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            chrome.border.nsColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 8, yRadius: 8).stroke()
            let symbol: String
            switch target {
            case .top: symbol = "arrow.up"
            case .right: symbol = "arrow.right"
            case .bottom: symbol = "arrow.down"
            case .left: symbol = "arrow.left"
            }
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold)
                    .applying(.init(paletteColors: [(active ? chrome.onAccent : chrome.text).nsColor]))) {
                let size = image.size
                image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    static func targetFrame(_ side: SplitDirection, in rect: CGRect) -> CGRect {
        let s: CGFloat = 36, inset: CGFloat = 14
        switch side {
        case .top: return CGRect(x: rect.midX - s / 2, y: rect.minY + inset, width: s, height: s)
        case .bottom: return CGRect(x: rect.midX - s / 2, y: rect.maxY - inset - s, width: s, height: s)
        case .left: return CGRect(x: rect.minX + inset, y: rect.midY - s / 2, width: s, height: s)
        case .right: return CGRect(x: rect.maxX - inset - s, y: rect.midY - s / 2, width: s, height: s)
        }
    }
}

/// "Pane 2 of 3 maximised" with a minimap of the layout and Restore.
struct MaximizedChip: View {
    let tab: TabModel
    let restore: () -> Void

    var body: some View {
        MaximizedChipContent(tab: tab, restore: restore).chromeEnvironment()
    }
}

private struct MaximizedChipContent: View {
    let tab: TabModel
    let restore: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        if let maximized = tab.maximizedPaneID {
            let panes = tab.layout.panes
            let index = (panes.firstIndex(of: maximized) ?? 0) + 1
            let map = CGRect(x: 0, y: 0, width: 36, height: 24)
            let frames = tab.layout.layout(in: map, spacing: 2)
            HStack(spacing: 10) {
                ZStack(alignment: .topLeading) {
                    ForEach(panes, id: \.self) { id in
                        if let f = frames[id] {
                            RoundedRectangle(cornerRadius: 2)
                                .fill((id == maximized ? chrome.accent : chrome.fillStrong).color)
                                .frame(width: f.width, height: f.height)
                                .offset(x: f.minX, y: f.minY)
                        }
                    }
                }
                .frame(width: map.width, height: map.height, alignment: .topLeading)
                Text(L("Pane {index} of {total} maximised", ["index": index, "total": panes.count])).font(ChromeFont.caption)
                Button(action: restore) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                        Text(L("Restore"))
                        if let key = StartPageView.shortcut("pane-maximize") {
                            Text(key).foregroundStyle(chrome.textFaint.color)
                        }
                    }
                    .font(ChromeFont.caption)
                }
                .buttonStyle(ChromeButtonStyle())
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .foregroundStyle(chrome.text.color)
            .background(Capsule().fill(chrome.surfaceRaised.color))
            .overlay(Capsule().strokeBorder(chrome.border.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            .padding(8)
            .fixedSize()
        }
    }
}
#endif
