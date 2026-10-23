#if canImport(AppKit)
import AppKit
import Observation
import SwiftUI
import TabbyCore

/// One upload or download (Tabby's `FileTransfer`).
@Observable
@MainActor
final class Transfer: Identifiable {
    enum Direction { case upload, download }
    enum Status: Equatable {
        case running, done, cancelled
        case failed(String)
    }

    let id = UUID()
    let name: String
    let direction: Direction
    let host: String
    /// Where a download landed (Show in Finder).
    var localURL: URL?
    private(set) var progress: TransferProgress
    private(set) var status: Status = .running
    private(set) var isCancelled = false

    init(name: String, direction: Direction, host: String, total: UInt64, localURL: URL? = nil) {
        self.name = name
        self.direction = direction
        self.host = host
        self.localURL = localURL
        progress = TransferProgress(total: total, start: Date())
    }

    var subtitle: String { direction == .upload ? "To \(host)" : "From \(host)" }
    var isRunning: Bool { status == .running }

    func record(_ bytes: UInt64) {
        progress.record(bytes: bytes, at: Date())
    }

    func setTotal(_ total: UInt64) {
        progress.setTotal(total)
    }

    func cancel() {
        guard isRunning else { return }
        isCancelled = true
    }

    func finish(_ status: Status) {
        guard isRunning else { return }
        self.status = status
    }
}

/// Every transfer of the app, newest last; the tab bar shows a button while there are any.
@Observable
@MainActor
final class TransferCenter {
    static let shared = TransferCenter()

    private(set) var transfers: [Transfer] = []
    /// Set when the first transfer starts; the toolbar opens its popover and clears it.
    var wantsPopover = false

    var activeCount: Int { transfers.filter(\.isRunning).count }
    /// "There are active file transfers": clearing asks first while some still run.
    var clearNeedsConfirmation: Bool { activeCount > 0 }

    @discardableResult
    func start(name: String, direction: Transfer.Direction, host: String, total: UInt64, localURL: URL? = nil) -> Transfer {
        if transfers.isEmpty { wantsPopover = true }
        let transfer = Transfer(name: name, direction: direction, host: host, total: total, localURL: localURL)
        transfers.append(transfer)
        return transfer
    }

    /// Starts a transfer and runs `body` with a progress reporter and a cancel check.
    @discardableResult
    func run(name: String, direction: Transfer.Direction, host: String, total: UInt64, localURL: URL? = nil,
             started: (Transfer) -> Void = { _ in },
             _ body: (_ report: @escaping (UInt64) -> Void, _ isCancelled: @escaping () -> Bool) async throws -> Void) async -> Transfer {
        let transfer = start(name: name, direction: direction, host: host, total: total, localURL: localURL)
        started(transfer)
        do {
            try await body({ transfer.record($0) }, { transfer.isCancelled })
            transfer.finish(transfer.isCancelled ? .cancelled : .done)
        } catch {
            if transfer.isCancelled || error is CancellationError {
                transfer.finish(.cancelled)
            } else {
                transfer.finish(.failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
        return transfer
    }

    func clearFinished() {
        transfers.removeAll { !$0.isRunning }
    }

    func abortAll() {
        for transfer in transfers where transfer.isRunning {
            transfer.cancel()
            transfer.finish(.cancelled)
        }
    }

    func remove(_ transfer: Transfer) {
        transfers.removeAll { $0 === transfer }
    }
}

/// The tab bar's transfers button: hidden without transfers, a badge with the running count,
/// opening by itself on the first transfer.
struct TransfersToolbarButton: View {
    @State private var center = TransferCenter.shared
    @State private var showsPopover = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        if !center.transfers.isEmpty {
            IconButton(symbol: "arrow.up.arrow.down", help: "Transfers") { showsPopover.toggle() }
                .overlay(alignment: .topTrailing) {
                    if center.activeCount > 0 {
                        Text("\(center.activeCount)").font(.system(size: 9, weight: .bold)).foregroundStyle(chrome.onAccent.color)
                            .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                            .background(Capsule().fill(chrome.accent.color)).offset(x: 3, y: -2)
                    }
                }
                .popover(isPresented: $showsPopover, arrowEdge: .bottom) { TransfersPopover(center: center).chromeEnvironment() }
                .onChange(of: center.wantsPopover, initial: true) { _, wants in
                    if wants {
                        showsPopover = true
                        center.wantsPopover = false
                    }
                }
        }
    }
}

struct TransfersPopover: View {
    let center: TransferCenter
    @State private var confirmClear = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transfers").font(ChromeFont.headline)
                Spacer()
                Button("Clear finished") {
                    if center.clearNeedsConfirmation { confirmClear = true } else { center.clearFinished() }
                }
                .buttonStyle(ChromeButtonStyle())
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(center.transfers) { TransferRow(transfer: $0, center: center) }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .frame(width: 380)
        .foregroundStyle(chrome.text.color)
        .confirmationDialog("There are active file transfers", isPresented: $confirmClear) {
            Button("Abort all", role: .destructive) {
                center.abortAll()
                center.clearFinished()
            }
            Button("Do not abort", role: .cancel) { center.clearFinished() }
        }
    }
}

private struct TransferRow: View {
    let transfer: Transfer
    let center: TransferCenter
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: transfer.direction == .upload ? "arrow.up" : "arrow.down").foregroundStyle(chrome.accent.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(transfer.name).font(ChromeFont.body).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(percent).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                }
                ProgressView(value: transfer.progress.fraction).tint(tint.color)
                Text(detail).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).lineLimit(1)
            }
            if transfer.isRunning {
                IconButton(symbol: "xmark", help: "Cancel", size: 22) { transfer.cancel() }
            } else if transfer.status == .done, let url = transfer.localURL {
                IconButton(symbol: "folder", help: "Show in Finder", size: 22) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            } else {
                IconButton(symbol: "checkmark", help: "Remove from the list", size: 22) { center.remove(transfer) }
            }
        }
    }

    private var tint: RGBColor {
        switch transfer.status {
        case .done: return chrome.success
        case .failed, .cancelled: return chrome.danger
        case .running: return chrome.accent
        }
    }

    private var percent: String { "\(Int((transfer.progress.fraction * 100).rounded()))%" }

    private var detail: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(transfer.progress.total), countStyle: .file)
        let done = ByteCountFormatter.string(fromByteCount: Int64(transfer.progress.completed), countStyle: .file)
        switch transfer.status {
        case .running:
            let speed = ByteCountFormatter.string(fromByteCount: Int64(transfer.progress.bytesPerSecond), countStyle: .file)
            return "\(transfer.subtitle) · \(done) of \(size) · \(speed)/s"
        case .done: return "\(transfer.subtitle) · \(size) · Done"
        case .cancelled: return "\(transfer.subtitle) · Cancelled"
        case .failed(let reason): return "\(transfer.subtitle) · \(reason)"
        }
    }
}
#endif
