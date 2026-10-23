#if canImport(AppKit)
import Observation
import SwiftUI
import TabbyCore
import TabbySSHLib

/// The forwards of a live connection and Tabby's "Add a port forward" form
/// (`SSHPortForwardingConfigComponent`): removing a forward puts it back in the form, which
/// is how it is edited.
@Observable
@MainActor
final class PortForwardsModel {
    private(set) var forwards: [ForwardStatus] = []
    var type: PortForwardType = .local
    var host = "127.0.0.1"
    var port = "8000"
    var targetAddress = "127.0.0.1"
    var targetPort = "80"
    var descriptionText = ""
    private(set) var error: String?
    private(set) var isBusy = false

    private let list: () -> [ForwardStatus]
    private let add: (ForwardedPort) async throws -> UUID
    private let removeForward: (UUID) async -> Void

    init(list: @escaping () -> [ForwardStatus], add: @escaping (ForwardedPort) async throws -> UUID,
         remove: @escaping (UUID) async -> Void) {
        self.list = list
        self.add = add
        removeForward = remove
        refresh()
    }

    /// Dynamic forwards are a SOCKS proxy: no target.
    var showsTarget: Bool { type != .dynamic }

    func refresh() {
        forwards = list()
    }

    func submit() async {
        guard let listenPort = Self.port(port) else { return error = L("The port must be a number from 1 to 65535.") }
        var forward = ForwardedPort(type: type, host: host.trimmingCharacters(in: .whitespaces), port: listenPort,
                                    description: descriptionText.trimmingCharacters(in: .whitespaces))
        if showsTarget {
            let address = targetAddress.trimmingCharacters(in: .whitespaces)
            guard !address.isEmpty else { return error = L("Enter the address to forward to.") }
            guard let target = Self.port(targetPort) else { return error = L("The target port must be a number from 1 to 65535.") }
            forward.targetAddress = address
            forward.targetPort = target
        }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await add(forward)
            error = nil
            descriptionText = ""
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        refresh()
    }

    func remove(_ status: ForwardStatus) async {
        let f = status.forward
        type = f.type
        host = f.host
        port = String(f.port)
        targetAddress = f.type == .dynamic ? targetAddress : f.targetAddress
        targetPort = f.type == .dynamic ? targetPort : String(f.targetPort)
        descriptionText = f.description
        await removeForward(status.id)
        refresh()
    }

    static func route(_ f: ForwardedPort) -> String {
        f.type == .dynamic ? "\(f.host):\(f.port) · SOCKS proxy" : "\(f.host):\(f.port) → \(f.targetAddress):\(f.targetPort)"
    }

    private static func port(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), (1...65535).contains(value) else { return nil }
        return value
    }
}

/// The chip's Ports popover (420 pt): the live forwards and the form.
struct PortsPopover: View {
    @Bindable var model: PortForwardsModel
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.forwards.isEmpty {
                GroupHeader(L("Forwarded ports"))
                VStack(spacing: 0) {
                    ForEach(model.forwards, id: \.id) { status in
                        row(status)
                    }
                }
            }
            GroupHeader(L("Add a port forward"))
            Picker("", selection: $model.type) {
                Text(L("Local")).tag(PortForwardType.local)
                Text(L("Remote")).tag(PortForwardType.remote)
                Text(L("Dynamic")).tag(PortForwardType.dynamic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                TextField(L("Host"), text: $model.host).frame(width: 110)
                Text(":").foregroundStyle(chrome.textMuted.color)
                TextField(L("Port"), text: $model.port).frame(width: 56)
                Image(systemName: "arrow.right").foregroundStyle(chrome.textMuted.color)
                if model.showsTarget {
                    TextField(L("Address"), text: $model.targetAddress).frame(width: 110)
                    Text(":").foregroundStyle(chrome.textMuted.color)
                    TextField(L("Port"), text: $model.targetPort).frame(width: 56)
                } else {
                    Text(L("SOCKS proxy")).foregroundStyle(chrome.textMuted.color)
                    Spacer()
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.custom("Menlo", size: 12))
            TextField(L("Description"), text: $model.descriptionText).textFieldStyle(.roundedBorder)
            if let error = model.error {
                Text(error).font(ChromeFont.caption).foregroundStyle(chrome.danger.color).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(L("Forward port")) { Task { await model.submit() } }
                    .buttonStyle(ChromeButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
        .padding(16)
        .frame(width: 420)
        .foregroundStyle(chrome.text.color)
    }

    private func row(_ status: ForwardStatus) -> some View {
        HStack(spacing: 8) {
            Text(status.forward.type.title)
                .font(ChromeFont.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(chrome.fill.color))
            Text(PortForwardsModel.route(status.forward)).font(.custom("Menlo", size: 12)).lineLimit(1)
            if !status.forward.description.isEmpty {
                Text(status.forward.description).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).lineLimit(1)
            }
            Spacer()
            IconButton(symbol: "xmark", help: L("Stop forwarding (puts it back in the form)"), size: 22) {
                Task { await model.remove(status) }
            }
        }
        .frame(height: metrics.selectorRow)
    }
}
#endif
