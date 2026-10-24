#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbyTerminal

/// Tabby's ZMODEM prompt (`zmodem.ts`).
enum ZModemUI {
    struct Question {
        let title: String
        let message: String
        let accept: String
        let reject: String
    }

    /// Tabby's message, and which tab asks (the question no longer brings it to the front).
    static func message(for tab: String) -> String {
        question.message + "\n\n" + L("Asked by the tab “{title}”.", ["title": tab])
    }

    static var question: Question {
        Question(title: L("Accept a ZMODEM session?"),
                 message: L("If you have not requested it, it could be a sign of malicious activity."),
                 accept: L("Accept"), reject: L("Reject"))
    }
}

/// A received file: written to disk as it arrives, shown as a download row.
final class ZModemFileWriter: ZModemFileSink {
    let url: URL
    private let handle: FileHandle
    private let transfer: Transfer
    private var reported: UInt64 = 0

    @MainActor
    init(url: URL, info: ZModemFileInfo, host: String) throws {
        self.url = url
        // Tabby opens with flag "w" and mode 0644; the save panel already asked about an
        // existing file.
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        handle = try FileHandle(forWritingTo: url)
        transfer = TransferCenter.shared.start(name: info.name, direction: .download, host: host, total: info.size ?? 0, localURL: url)
    }

    var isCancelled: Bool { MainActor.assumeIsolated { transfer.isCancelled } }

    func write(_ bytes: [UInt8]) throws {
        try handle.write(contentsOf: Data(bytes))
    }

    func progress(_ bytes: UInt64) {
        let delta = bytes > reported ? bytes - reported : 0
        reported = bytes
        MainActor.assumeIsolated { transfer.record(delta) }
    }

    func finish(_ outcome: ZModemOutcome) {
        try? handle.close()
        MainActor.assumeIsolated {
            switch outcome {
            case .done:
                transfer.finish(.done)
            case .skipped, .cancelled:
                // ★ A half-received file is removed (Tabby leaves it).
                try? FileManager.default.removeItem(at: url)
                transfer.finish(.cancelled)
            case .failed(let reason):
                try? FileManager.default.removeItem(at: url)
                transfer.finish(.failed(reason))
            }
        }
    }
}

/// A file to send: read from disk as the remote asks, shown as an upload row.
final class ZModemFileReader: ZModemTransferHandle {
    private let handle: FileHandle
    private let transfer: Transfer
    private var reported: UInt64 = 0

    @MainActor
    static func upload(_ url: URL, host: String) -> ZModemUpload? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let info = ZModemFileInfo(name: url.lastPathComponent, size: size, mtime: attributes[.modificationDate] as? Date,
                                  mode: (attributes[.posixPermissions] as? NSNumber).map { 0o100000 | $0.uint32Value })
        let reader = ZModemFileReader(handle: handle, transfer: TransferCenter.shared.start(
            name: url.lastPathComponent, direction: .upload, host: host, total: size))
        let file = ZModemOutgoingFile(info: info) { [weak reader] offset, count in reader?.read(offset, count) ?? [] }
        return ZModemUpload(file: file, handle: reader)
    }

    private init(handle: FileHandle, transfer: Transfer) {
        self.handle = handle
        self.transfer = transfer
    }

    private func read(_ offset: UInt64, _ count: Int) -> [UInt8] {
        do {
            try handle.seek(toOffset: offset)
            return Array(try handle.read(upToCount: count) ?? Data())
        } catch {
            return []
        }
    }

    var isCancelled: Bool { MainActor.assumeIsolated { transfer.isCancelled } }

    func progress(_ bytes: UInt64) {
        let delta = bytes > reported ? bytes - reported : 0
        reported = bytes
        MainActor.assumeIsolated { transfer.record(delta) }
    }

    func finish(_ outcome: ZModemOutcome) {
        try? handle.close()
        MainActor.assumeIsolated {
            switch outcome {
            case .done: transfer.finish(.done)
            case .skipped, .cancelled: transfer.finish(.cancelled)
            case .failed(let reason): transfer.finish(.failed(reason))
            }
        }
    }
}

extension MainWindowController: ZModemHost {
    typealias ZModemAsk = (_ window: NSWindow?, _ tab: String, _ answer: @escaping (Bool) -> Void) -> Void
    typealias ZModemSavePanel = (_ window: NSWindow?, _ name: String, _ folder: URL?, _ done: @escaping (URL?) -> Void) -> Void
    typealias ZModemOpenPanel = (_ window: NSWindow?, _ done: @escaping ([URL]) -> Void) -> Void

    static let defaultZModemAsk: ZModemAsk = { window, tab, answer in
        let q = ZModemUI.question
        Prompts.confirm(in: window, title: q.title, message: ZModemUI.message(for: tab), confirm: q.accept, cancel: q.reject,
                        completion: answer)
    }
    static let defaultZModemSavePanel: ZModemSavePanel = { window, name, folder, done in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let folder { panel.directoryURL = folder }
        if let window {
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        } else {
            done(panel.runModal() == .OK ? panel.url : nil)
        }
    }
    static let defaultZModemOpenPanel: ZModemOpenPanel = { window, done in
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = L("Select")
        if let window {
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.urls : []) }
        } else {
            done(panel.runModal() == .OK ? panel.urls : [])
        }
    }
    /// The question, and the save and open panels (tests answer them).
    static var zmodemAsk: ZModemAsk = defaultZModemAsk
    static var zmodemSavePanel: ZModemSavePanel = defaultZModemSavePanel
    static var zmodemOpenPanel: ZModemOpenPanel = defaultZModemOpenPanel

    func zmodemAsk(_ direction: ZModemDirection, in pane: TerminalPane, answer: @escaping (Bool) -> Void) {
        // ★ Names the tab instead of switching to it: any host can start a session at will.
        Self.zmodemAsk(window, pane.title, answer)
    }

    func zmodemSave(_ info: ZModemFileInfo, in pane: TerminalPane, answer: @escaping (ZModemFileSink?) -> Void) {
        // ★ A local pane's folder, as Export to file (Tabby's dialog has none).
        let folder = pane.profile.type == "local" ? pane.currentDirectory().map { URL(fileURLWithPath: $0) } : nil
        Self.zmodemSavePanel(window, info.name, folder) { [weak self] url in
            guard let url else { return answer(nil) }
            do {
                answer(try ZModemFileWriter(url: url, info: info, host: pane.title))
            } catch {
                self?.toasts.show(ToastCenter.Toast(symbol: "exclamationmark.triangle", tint: .warning, title: L("Could not save the file"),
                                                    detail: error.localizedDescription))
                answer(nil)
            }
        }
    }

    func zmodemChooseFiles(in pane: TerminalPane, answer: @escaping ([ZModemUpload]) -> Void) {
        Self.zmodemOpenPanel(window) { urls in
            answer(urls.compactMap { ZModemFileReader.upload($0, host: pane.title) })
        }
    }
}
#endif
