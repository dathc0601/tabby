#if canImport(AppKit)
import SwiftUI
import Observation
import TabbyCore

/// The baud-rate popover's state (design C2): the standard rates with the one in use, and a
/// Custom field. A rate applies at once and closes the popover.
@MainActor
@Observable
final class BaudRatePopoverModel: Identifiable {
    let device: String
    let current: Int?
    let rates = BaudRates.standard
    /// The Custom field; it shows a rate in use that is not standard.
    var custom: String
    /// Set once a rate was applied: the popover closes.
    private(set) var isFinished = false
    private let apply: (Int) -> Void

    init(device: String, current: Int?, apply: @escaping (Int) -> Void) {
        self.device = device
        self.current = current
        self.apply = apply
        custom = current.map { BaudRates.standard.contains($0) ? "" : String($0) } ?? ""
    }

    func isCurrent(_ rate: Int) -> Bool { rate == current }

    /// The Custom field's rate: a positive whole number.
    var customRate: Int? {
        Int(custom.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    func choose(_ rate: Int) {
        apply(rate)
        isFinished = true
    }

    /// ↩: applies the Custom field when it holds a rate.
    func submit() {
        if let rate = customRate { choose(rate) }
    }
}

struct BaudRatePopover: View {
    @Bindable var model: BaudRatePopoverModel
    @State private var hovered: Int?
    @FocusState private var customFocused: Bool
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Baud rate").font(ChromeFont.bodyEmphasised)
                Spacer(minLength: 8)
                Text(verbatim: model.device).font(.custom("Menlo", size: 11.5)).foregroundStyle(chrome.textMuted.color).lineLimit(1)
            }
            .padding(EdgeInsets(top: 4, leading: 8, bottom: 6, trailing: 8))
            ForEach(model.rates, id: \.self) { rate in
                rateRow(rate)
            }
            separator
            HStack(spacing: 8) {
                Color.clear.frame(width: 16, height: 1)
                Text("Custom")
                Spacer(minLength: 8)
                TextField("", text: $model.custom)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .focused($customFocused)
                    .onSubmit { model.submit() }
                    .accessibilityLabel("Custom baud rate")
            }
            .frame(height: 32)
            .padding(.horizontal, 8)
            separator
            HStack(spacing: 8) {
                Spacer()
                Keycap("↩ apply")
                Keycap("esc close")
            }
            .padding(EdgeInsets(top: 1, leading: 8, bottom: 2, trailing: 8))
        }
        .padding(6)
        .frame(width: 320)
        .foregroundStyle(chrome.text.color)
        .onAppear { customFocused = !model.custom.isEmpty }
    }

    private var separator: some View {
        Rectangle().fill(chrome.separator.color).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func rateRow(_ rate: Int) -> some View {
        let current = model.isCurrent(rate)
        return Button { model.choose(rate) } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(chrome.accent.color)
                    .opacity(current ? 1 : 0)
                    .frame(width: 16)
                Text(verbatim: String(rate))
                    .monospacedDigit()
                    .fontWeight(current ? .semibold : .regular)
                Spacer(minLength: 8)
                if current {
                    Text("In use").font(.system(size: 11)).foregroundStyle(chrome.textMuted.color)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered == rate ? chrome.fill.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? rate : (hovered == rate ? nil : hovered) }
    }
}

/// The chip's "Baud rate" button: shown pressed while its popover is open.
struct BaudRateButton: View {
    let enabled: Bool
    /// The popover's model for the open port (nil: none).
    let makeModel: () -> BaudRatePopoverModel?
    /// True while the popover shows (the chip stays while it is open).
    @Binding var isOpen: Bool
    @State private var model: BaudRatePopoverModel?
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button { model = makeModel() } label: {
            Label("Baud rate", systemImage: "speedometer")
                .font(ChromeFont.caption)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(model != nil ? chrome.fillStrong.color : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle((model != nil ? chrome.text : enabled ? chrome.textMuted : chrome.textFaint).color)
        .disabled(!enabled)
        .popover(item: $model, arrowEdge: .bottom) { BaudRatePopover(model: $0).chromeEnvironment() }
        .onChange(of: model == nil) { _, closed in isOpen = !closed }
        .onChange(of: model?.isFinished ?? false) { _, finished in if finished { model = nil } }
    }
}
#endif
