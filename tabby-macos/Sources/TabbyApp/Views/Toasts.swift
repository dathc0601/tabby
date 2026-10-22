#if canImport(AppKit)
import SwiftUI
import Observation
import TabbyCore

/// In-app toasts of one window (Tabby's `NotificationsService` toasts): at most three, newest
/// last, each gone after a few seconds.
@MainActor
@Observable
final class ToastCenter {
    enum Tint { case success, danger, warning, accent }

    struct Toast: Identifiable {
        let id = UUID()
        var symbol: String
        var tint: Tint
        var title: String
        var detail: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private(set) var toasts: [Toast] = []
    static let limit = 3

    func show(_ toast: Toast, for seconds: TimeInterval = 6) {
        toasts.append(toast)
        if toasts.count > Self.limit { toasts.removeFirst(toasts.count - Self.limit) }
        let id = toast.id
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(id) }
        }
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }

    /// "12s", "3m 12s", "1h 4m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

/// The toasts at the bottom right of a window.
struct ToastOverlay: View {
    let center: ToastCenter

    var body: some View {
        ToastStack(center: center).chromeEnvironment()
    }
}

private struct ToastStack: View {
    let center: ToastCenter
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(center.toasts) { toast in
                ToastView(toast: toast) { center.dismiss(toast.id) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(14)
        .animation(.easeOut(duration: 0.18), value: center.toasts.map(\.id))
        .fixedSize()
    }
}

struct ToastView: View {
    let toast: ToastCenter.Toast
    let close: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        let tint: RGBColor = {
            switch toast.tint {
            case .success: return chrome.success
            case .danger: return chrome.danger
            case .warning: return chrome.warning
            case .accent: return chrome.accent
            }
        }()
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.symbol).font(.system(size: 16)).foregroundStyle(tint.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title).font(ChromeFont.bodyEmphasised)
                if !toast.detail.isEmpty {
                    Text(toast.detail).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                        .lineLimit(2).frame(maxWidth: 300, alignment: .leading)
                }
            }
            if let title = toast.actionTitle, let action = toast.action {
                Button(title) {
                    action()
                    close()
                }
                .buttonStyle(ChromeButtonStyle())
            }
            IconButton(symbol: "xmark", help: "Dismiss", size: 20, action: close)
        }
        .padding(12)
        .foregroundStyle(chrome.text.color)
        .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    }
}
#endif
