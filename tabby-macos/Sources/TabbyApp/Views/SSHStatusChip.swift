#if canImport(AppKit)
import SwiftUI
import Observation
import TabbyCore
import TabbySSHLib
import TabbyTerminal

/// Whether the pointer is over a pane (the chip shows on hover).
@MainActor
@Observable
final class PaneHover {
    var isHovering = false
}

/// The SSH status chip from the design's component board: a state dot, `user@host:port`, the
/// state and Reconnect. It shows while the pointer is over the pane, and whenever the
/// connection is not up.
struct SSHStatusChip: View {
    let pane: TerminalPane
    let hover: PaneHover

    var body: some View {
        ChipContent(pane: pane, hover: hover).chromeEnvironment()
    }

    /// `user@host:port`. Verbatim: an interpolated Int in a localized `Text` gets the locale's
    /// digit grouping (`2.222` in Vietnamese, `2,222` in English).
    static func address(_ options: SSHOptions) -> Text {
        Text(verbatim: "\(options.user)@\(options.host):\(options.port)")
    }
}

private struct ChipContent: View {
    let pane: TerminalPane
    let hover: PaneHover
    @Environment(\.chrome) private var chrome
    @State private var showsPorts = false

    var body: some View {
        // Stays while its popover is open: the pointer leaves the pane to use it.
        if let state = pane.connectionState, hover.isHovering || state != .connected || showsPorts {
            let options = SSHOptions(pane.profile.options)
            HStack(spacing: 8) {
                StatusDot(color: Self.color(state, chrome), size: 7)
                SSHStatusChip.address(options).font(.custom("Menlo", size: 12)).lineLimit(1)
                Text(Self.label(state)).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                if state == .disconnected || state == .connected {
                    Button { reconnect(state, options) } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise").font(ChromeFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle((state == .disconnected ? chrome.accent : chrome.textMuted).color)
                }
                if let session = pane.session as? LibSSHSession {
                    Rectangle().fill(chrome.separator.color).frame(width: 1, height: 14)
                    PortsButton(enabled: state == .connected, makeModel: { Self.portsModel(session) }, isOpen: $showsPorts)
                    Button { SFTPPanels.shared.toggle(for: pane) } label: {
                        Label("SFTP", systemImage: "folder").font(ChromeFont.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle((state == .connected ? chrome.textMuted : chrome.textFaint).color)
                    .disabled(state != .connected)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(chrome.text.color)
            .background(Capsule().fill(chrome.surfaceRaised.color))
            .overlay(Capsule().strokeBorder(chrome.border.color, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .padding(8)
            .fixedSize()
        }
    }

    /// The Ports popover's model for the session's live connection.
    private static func portsModel(_ session: LibSSHSession) -> PortForwardsModel? {
        guard let connection = session.connection else { return nil }
        return PortForwardsModel(list: { connection.forwards },
                                 add: { try await connection.addForward($0) },
                                 remove: { await connection.removeForward($0) })
    }

    /// A live session is restarted only after asking: whatever runs in it ends.
    private func reconnect(_ state: TerminalPane.ConnectionState, _ options: SSHOptions) {
        guard state == .connected else { return pane.restart() }
        Prompts.confirm(in: NSApp.keyWindow, title: "Reconnect to \(options.host)?",
                        message: "The session is restarted; anything running in it ends.", confirm: "Reconnect") { ok in
            if ok { pane.restart() }
        }
    }

    static func color(_ state: TerminalPane.ConnectionState, _ chrome: ChromeTheme) -> RGBColor {
        switch state {
        case .connected: return chrome.success
        case .disconnected: return chrome.danger
        case .connecting, .reconnecting: return chrome.warning
        }
    }

    static func label(_ state: TerminalPane.ConnectionState) -> String {
        switch state {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case let .reconnecting(attempt, total): return "Reconnecting \(attempt)/\(total)"
        }
    }
}

/// The chip's Ports button and its popover of live port forwards. Presented by item: with a
/// flag and the model in separate state, the first popover was built before the model was
/// set and opened empty (M8).
struct PortsButton: View {
    let enabled: Bool
    /// The popover's model for the live connection (nil: none).
    let makeModel: () -> PortForwardsModel?
    /// True while the popover shows (the chip stays while it is open).
    @Binding var isOpen: Bool
    @State private var model: PortForwardsModel?
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button { model = makeModel() } label: {
            Label("Ports", systemImage: "point.3.connected.trianglepath.dotted").font(ChromeFont.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle((enabled ? chrome.textMuted : chrome.textFaint).color)
        .disabled(!enabled)
        .popover(item: $model, arrowEdge: .bottom) { PortsPopover(model: $0).chromeEnvironment() }
        .onChange(of: model == nil) { _, closed in isOpen = !closed }
    }
}

extension PortForwardsModel: Identifiable {}
#endif
