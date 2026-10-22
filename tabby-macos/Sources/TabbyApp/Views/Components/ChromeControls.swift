#if canImport(AppKit)
import SwiftUI
import TabbyCore

/// Push button from the design's component board: 24 pt (28 pt large), radius 6.
struct ChromeButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, plain }
    var kind: Kind = .secondary
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, large: large)
    }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        @Environment(\.chrome) private var chrome
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(kind == .primary ? ChromeFont.bodyEmphasised : ChromeFont.body)
                .lineLimit(1)
                .padding(.horizontal, large ? 14 : 10)
                .frame(minHeight: large ? 28 : 24)
                .foregroundStyle(foreground.color)
                .background(RoundedRectangle(cornerRadius: 6).fill(background(pressed: pressed).color))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(kind == .secondary ? chrome.border.color : .clear, lineWidth: 0.5))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }

        private var foreground: RGBColor {
            switch kind {
            case .primary: return chrome.onAccent
            case .destructive: return chrome.danger.luminance > 0.4 ? .black : .white
            case .secondary, .plain: return chrome.text
            }
        }

        private func background(pressed: Bool) -> RGBColor {
            switch kind {
            case .primary: return pressed ? chrome.accent.mixOKLab(.black, 0.15) : chrome.accent
            case .destructive: return pressed ? chrome.danger.mixOKLab(.black, 0.15) : chrome.danger
            case .secondary: return pressed ? chrome.fillStrong.withAlpha(0.22) : chrome.fillStrong
            case .plain: return pressed ? chrome.fillStrong : .black.withAlpha(0)
            }
        }
    }
}

/// Toolbar icon button: 28 × 28 pt, SF Symbol 15 pt. Hover fills, pressing fills more, and
/// `isActive` marks a toggled-on tool.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var isActive = false
    var size: CGFloat = 28
    var tint: RGBColor?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size * 15 / 28))
        }
        .buttonStyle(IconButtonStyle(isActive: isActive, size: size, tint: tint))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct IconButtonStyle: ButtonStyle {
    var isActive = false
    var size: CGFloat = 28
    var tint: RGBColor?

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isActive: isActive, size: size, tint: tint)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isActive: Bool
        let size: CGFloat
        let tint: RGBColor?
        @Environment(\.chrome) private var chrome
        @State private var hovering = false

        var body: some View {
            let fill: RGBColor? = configuration.isPressed ? chrome.fillStrong
                : isActive ? chrome.accentFill
                : hovering ? chrome.fill : nil
            let fg = tint ?? (isActive ? chrome.accent : (hovering || configuration.isPressed ? chrome.text : chrome.textMuted))
            configuration.label
                .frame(width: size, height: size)
                .foregroundStyle(fg.color)
                .background(RoundedRectangle(cornerRadius: 6).fill(fill?.color ?? .clear))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

/// A key or chord rendered as a keycap (`⌘E`, `↩ open`).
struct Keycap: View {
    let text: String
    var removable: (() -> Void)?
    @Environment(\.chrome) private var chrome

    init(_ text: String, removable: (() -> Void)? = nil) {
        self.text = text
        self.removable = removable
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(text).font(.system(size: 11, weight: .medium)).monospacedDigit()
            if let removable {
                Button(action: removable) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(chrome.textMuted.color)
                    .help("Remove")
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 18)
        .foregroundStyle(chrome.text.color)
        .background(Capsule().fill(chrome.fillStrong.color))
        .fixedSize()
    }
}

/// 11 pt semibold group header used by the selector, the profile list and settings groups.
struct GroupHeader: View {
    let title: String
    @Environment(\.chrome) private var chrome

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(ChromeFont.groupHeader)
            .tracking(0.3)
            .foregroundStyle(chrome.textMuted.color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small coloured dot (connection state, activity, profile colour).
struct StatusDot: View {
    let color: RGBColor
    var size: CGFloat = 6

    var body: some View {
        Circle().fill(color.color).frame(width: size, height: size)
    }
}
#endif
