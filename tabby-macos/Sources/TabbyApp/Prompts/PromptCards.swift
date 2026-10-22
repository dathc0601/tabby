#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Presents SwiftUI content as a sheet on a window (the design's cards), or as a modal panel
/// when there is no window or it already shows a sheet. `content` gets a `dismiss` closure.
@MainActor
enum ChromeSheet {
    static func present<Content: View>(in window: NSWindow?, @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                            styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        let parent = window?.attachedSheet == nil ? window : nil
        var finished = false
        let dismiss = { [weak panel, weak parent] in
            guard !finished, let panel else { return }
            finished = true
            if let parent {
                parent.endSheet(panel)
            } else {
                NSApp.stopModal()
                panel.orderOut(nil)
            }
        }
        let controller = NSHostingController(rootView: AnyView(content(dismiss).chromeEnvironment()))
        panel.contentViewController = controller
        panel.setContentSize(controller.view.fittingSize)
        if let parent {
            parent.beginSheet(panel)
        } else {
            panel.center()
            NSApp.runModal(for: panel)
        }
    }
}

/// Icon, title and message at the top of a card.
private struct CardHeader: View {
    let symbol: String
    let tint: RGBColor
    let title: String
    let message: String
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(tint.color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(tint.withAlpha(0.18).color))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ChromeFont.headline)
                if !message.isEmpty {
                    Text(message).font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Cancel (esc) and the default action (↩), right-aligned.
private struct CardButtons: View {
    let cancel: String
    let confirm: String
    var destructive = false
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: onCancel) { Text(cancel) }
                .buttonStyle(ChromeButtonStyle(large: true))
                .keyboardShortcut(.cancelAction)
            Button(action: onConfirm) { Text(confirm) }
                .buttonStyle(ChromeButtonStyle(kind: destructive ? .destructive : .primary, large: true))
                .keyboardShortcut(.defaultAction)
        }
    }
}

/// Multi-line paste warning (Tabby's paste confirmation): a read-only preview of what will
/// run.
struct PasteWarningCard: View {
    let text: String
    let finish: (_ paste: Bool, _ dontAskAgain: Bool) -> Void
    @State private var dontAsk = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let count = lines.split(separator: "\n", omittingEmptySubsequences: true).count
        let preview = lines.count > 2000 ? String(lines.prefix(2000)) + "…" : lines
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(symbol: "doc.on.clipboard", tint: chrome.warning, title: "Paste multiple lines?",
                       message: "The clipboard holds \(count) lines. Each line runs as soon as it reaches the shell.")
            ScrollView {
                Text(preview).font(.custom("Menlo", size: 12)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 7).fill(chrome.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(chrome.border.color, lineWidth: 0.5))
            Toggle("Don't ask again", isOn: $dontAsk).toggleStyle(.checkbox)
            CardButtons(cancel: "Cancel", confirm: "Paste", onCancel: { finish(false, false) }, onConfirm: { finish(true, dontAsk) })
        }
        .padding(20)
        .frame(width: 460)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
    }
}

/// A text or password prompt with an optional "Remember" checkbox (Tabby's
/// `PromptModalComponent`, the design's small modals).
struct TextPromptCard: View {
    let symbol: String
    let title: String
    let message: String
    let secure: Bool
    let remember: String?
    let confirm: String
    let finish: (_ value: String?, _ remember: Bool) -> Void
    @State var value: String
    @State private var rememberOn = true
    @FocusState private var focused: Bool
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(symbol: symbol, tint: chrome.accent, title: title, message: message)
            Group {
                if secure {
                    SecureField("", text: $value)
                } else {
                    TextField("", text: $value)
                }
            }
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { finish(value, remember != nil && rememberOn) }
            if let remember {
                Toggle(remember, isOn: $rememberOn).toggleStyle(.checkbox)
            }
            CardButtons(cancel: "Cancel", confirm: confirm, onCancel: { finish(nil, false) },
                        onConfirm: { finish(value, remember != nil && rememberOn) })
        }
        .padding(20)
        .frame(width: 400)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .onAppear { focused = true }
    }
}

/// Host key verification (Tabby's `HostKeyPromptModal`, the design's "Verify host key").
struct HostKeyPromptCard: View {
    let host: String
    let keyType: String?
    let fingerprint: String?
    let finish: (_ accept: Bool) -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(symbol: "key", tint: chrome.warning, title: "Verify host key",
                       message: "This is the first connection to \(host). Compare the fingerprint with the one your administrator gave you before accepting.")
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Host").foregroundStyle(chrome.textMuted.color)
                    Text(host).font(.custom("Menlo", size: 12)).textSelection(.enabled)
                }
                GridRow {
                    Text("Key type").foregroundStyle(chrome.textMuted.color)
                    Text(keyType ?? "unknown").font(.custom("Menlo", size: 12))
                }
                GridRow(alignment: .top) {
                    Text("Fingerprint").foregroundStyle(chrome.textMuted.color)
                    FingerprintField(text: fingerprint ?? "unknown", color: chrome.text).frame(width: 300)
                }
            }
            .font(ChromeFont.body)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(chrome.surface.color))
            Text("Accepting saves the key in known_hosts.").font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
            CardButtons(cancel: "Reject", confirm: "Accept", onCancel: { finish(false) }, onConfirm: { finish(true) })
        }
        .padding(20)
        .frame(width: 480)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
    }
}

/// The fingerprint in its own selectable field that wraps at any character and never
/// hyphenates (AppKit hyphenated it in alert text, putting a "-" into the fingerprint).
struct FingerprintField: NSViewRepresentable {
    let text: String
    let color: RGBColor

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.isSelectable = true
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 300
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byCharWrapping
        style.hyphenationFactor = 0
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: color.nsColor,
            .paragraphStyle: style,
        ])
    }
}
#endif
