#if canImport(AppKit)
import SwiftUI
import TabbyCore

/// A titled group of settings rows on a raised card, rows separated by hairlines (the design's
/// `Form(.grouped)` look, drawn by hand so it follows the scheme tokens).
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content
    @Environment(\.chrome) private var chrome

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(chrome.textMuted.color).padding(.leading, 2)
            }
            _VariadicView.Tree(DividedRows(separator: chrome.separator)) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
            if let footer {
                Text(footer).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).padding(.leading, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Stacks the rows of a group with a separator between neighbours.
private struct DividedRows: _VariadicView_MultiViewRoot {
    let separator: RGBColor

    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { child in
                if child.id != children.first?.id {
                    Rectangle().fill(separator.color).frame(height: 1)
                }
                child
            }
        }
    }
}

/// One row: label (and optional subtitle) on the leading side, the control on the trailing
/// side; 40 pt tall, 52 pt with a subtitle, × spaciness.
struct SettingsRow<Control: View>: View {
    let label: String
    var subtitle: String?
    @ViewBuilder var control: Control
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics

    init(_ label: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.subtitle = subtitle
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(ChromeFont.body).foregroundStyle(chrome.text.color)
                if let subtitle {
                    Text(subtitle).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: CGFloat(subtitle == nil ? metrics.formRow : metrics.formRowTall))
    }
}

extension SettingsRow where Control == SettingsSwitch {
    /// A row with a switch bound to a config path or any boolean.
    init(_ label: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.init(label, subtitle: subtitle) { SettingsSwitch(isOn: isOn) }
    }
}

/// The small macOS switch, tinted with the scheme accent.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.chrome) private var chrome

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(chrome.accent.color)
    }
}

/// A page of settings: title, optional accessory, then groups, at most 760 pt wide.
struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.chrome) private var chrome

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(title).font(ChromeFont.title).foregroundStyle(chrome.text.color)
                content
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
