#if canImport(AppKit)
import AppKit
import Observation
import TabbyCore
import TabbySSHLib
import TabbyTerminal

/// Open SFTP panels by pane, for the pane views to show (like KeyboardInteractivePanels).
@Observable
@MainActor
final class SFTPPanels {
    static let shared = SFTPPanels()
    private(set) var controllers: [UUID: SFTPPanelController] = [:]
    /// The last folder per host, for the next panel there.
    @ObservationIgnored private var lastPaths: [String: String] = [:]

    /// Whether `pane` can show one: a connected session on the library backend.
    static func canOpen(_ pane: TerminalPane) -> Bool {
        (pane.session as? LibSSHSession)?.connection != nil && pane.connectionState == .connected
    }

    func open(for pane: TerminalPane) {
        if controllers[pane.id] != nil { return }
        guard let session = pane.session as? LibSSHSession, let connection = session.connection else { return }
        let host = session.options.host
        let start = SFTPPanelModel.startPath(shellDirectory: pane.workingDirectory, last: lastPaths[host])
        Task {
            do {
                let client = try await connection.sftp()
                let controller = SFTPPanelController(model: SFTPPanelModel(host: host, client: client), client: client, paneID: pane.id,
                                                     owner: ObjectIdentifier(session))
                controllers[pane.id] = controller
                await controller.model.navigate(to: start)
            } catch {
                WindowManager.shared.activeController?.toasts.show(ToastCenter.Toast(
                    symbol: "folder", tint: .danger, title: "SFTP", detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
            }
        }
    }

    /// Shows a ready controller (also used by tests).
    func present(_ controller: SFTPPanelController) {
        controllers[controller.paneID] = controller
    }

    func close(_ paneID: UUID) {
        guard let controller = controllers.removeValue(forKey: paneID) else { return }
        lastPaths[controller.model.host] = controller.model.path
    }

    /// Closes the panels of a session that ended.
    func close(owner: ObjectIdentifier) {
        for (paneID, controller) in controllers where controller.owner == owner {
            close(paneID)
        }
    }

    func toggle(for pane: TerminalPane) {
        if controllers[pane.id] != nil { close(pane.id) } else { open(for: pane) }
    }
}

/// The SFTP panel's actions that need AppKit (save and open panels, Finder, the default
/// app) and transfers.
@MainActor
final class SFTPPanelController {
    let model: SFTPPanelModel
    let client: SFTPOperations
    let paneID: UUID
    /// The session it belongs to; the panel closes when that session ends.
    let owner: ObjectIdentifier

    init(model: SFTPPanelModel, client: SFTPOperations, paneID: UUID, owner: ObjectIdentifier) {
        self.model = model
        self.client = client
        self.paneID = paneID
        self.owner = owner
    }

    var host: String { model.host }

    private var window: NSWindow? {
        WindowManager.shared.controllers.first { $0.model.tabs.contains { $0.panes[paneID] != nil } }?.window ?? NSApp.keyWindow
    }

    private func toast(_ title: String, _ detail: String, error: Bool = true) {
        let controller = WindowManager.shared.controllers.first { $0.window === window } ?? WindowManager.shared.activeController
        controller?.toasts.show(ToastCenter.Toast(symbol: "folder", tint: error ? .danger : .success, title: title, detail: detail))
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: Opening

    func activate(_ entry: SFTPEntry) {
        Task {
            if case .download(let file) = await model.open(entry) { download(file) }
        }
    }

    // MARK: Downloads

    func download(_ entry: SFTPEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = SFTPPath.safeLocalName(entry.name) ?? "download"
        panel.beginSheetModal(for: window ?? NSWindow()) { [self] response in
            guard response == .OK, let url = panel.url else { return }
            let client = client
            Task {
                await TransferCenter.shared.run(name: entry.name, direction: .download, host: host, total: entry.size, localURL: url) { report, cancelled in
                    try await client.download(entry.path, to: url, progress: report, isCancelled: cancelled)
                }
            }
        }
    }

    /// Tabby's "Download directory": pick a folder ("Download here"); a name clash gets
    /// "name (1)".
    func downloadDirectory(_ entry: SFTPEntry) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download here"
        panel.message = "Select destination folder for \(entry.name)"
        panel.beginSheetModal(for: window ?? NSWindow()) { [self] response in
            guard response == .OK, let folder = panel.url, let name = SFTPPath.safeLocalName(entry.name) else { return }
            let unique = SFTPPath.uniqueName(name) { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            let destination = folder.appendingPathComponent(unique)
            let client = client
            Task {
                var started: Transfer?
                await TransferCenter.shared.run(name: entry.name, direction: .download, host: host, total: 0, localURL: destination,
                                                started: { started = $0 }) { report, cancelled in
                    let files = try await Self.remoteTree(client, entry.path, relative: "")
                    started?.setTotal(files.reduce(0) { $0 + $1.size })
                    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                    for file in files {
                        guard !cancelled() else { throw SSHConnectionError.cancelled }
                        let local = destination.appendingPathComponent(file.relative)
                        if file.isDirectory {
                            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                        } else {
                            try await client.download(file.path, to: local, progress: report, isCancelled: cancelled)
                        }
                    }
                }
            }
        }
    }

    struct RemoteItem {
        var path: String
        var relative: String
        var isDirectory: Bool
        var size: UInt64
    }

    /// Everything under `path`, folders before their contents; names that could leave the
    /// destination folder are skipped.
    static func remoteTree(_ client: SFTPOperations, _ path: String, relative: String) async throws -> [RemoteItem] {
        var items: [RemoteItem] = []
        for entry in try await client.list(path) {
            guard let name = SFTPPath.safeLocalName(entry.name), !entry.isSymlink else { continue }
            let child = relative.isEmpty ? name : relative + "/" + name
            if entry.isDirectory {
                items.append(RemoteItem(path: entry.path, relative: child, isDirectory: true, size: 0))
                items += try await remoteTree(client, entry.path, relative: child)
            } else {
                items.append(RemoteItem(path: entry.path, relative: child, isDirectory: false, size: entry.size))
            }
        }
        return items
    }

    // MARK: Uploads

    func chooseFilesToUpload() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Upload"
        panel.beginSheetModal(for: window ?? NSWindow()) { [self] response in
            guard response == .OK else { return }
            upload(panel.urls)
        }
    }

    func chooseFolderToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Upload"
        panel.beginSheetModal(for: window ?? NSWindow()) { [self] response in
            guard response == .OK else { return }
            upload(panel.urls)
        }
    }

    /// Files and folders (recursively) into the current folder; also what a drop from
    /// Finder does.
    func upload(_ urls: [URL]) {
        let directory = model.path
        let client = client
        Task {
            for url in urls {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
                let total = Self.localSize(url)
                await TransferCenter.shared.run(name: url.lastPathComponent, direction: .upload, host: host, total: total) { report, cancelled in
                    try await Self.upload(url, into: directory, client: client, report: report, cancelled: cancelled)
                }
            }
            await model.refresh()
        }
    }

    static func upload(_ url: URL, into directory: String, client: SFTPOperations, report: @escaping (UInt64) -> Void,
                       cancelled: @escaping () -> Bool) async throws {
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        let remote = SFTPPath.join(directory, url.lastPathComponent)
        if isFolder.boolValue {
            try? await client.makeDirectory(remote, mode: 0o755)
            let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            for child in children {
                guard !cancelled() else { throw SSHConnectionError.cancelled }
                try await upload(child, into: remote, client: client, report: report, cancelled: cancelled)
            }
        } else {
            let mode = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber)?.uint32Value ?? 0o644
            try await client.upload(url, to: remote, mode: mode & 0o777, progress: report, isCancelled: cancelled)
        }
    }

    static func localSize(_ url: URL) -> UInt64 {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        guard isFolder.boolValue else {
            return ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
        }
        let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        var total: UInt64 = 0
        while let file = files?.nextObject() as? URL {
            total += UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    // MARK: Other actions

    func copyPath(_ entry: SFTPEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.path, forType: .string)
    }

    func createDirectory() {
        Prompts.text(in: window, title: "Name for the new directory", confirm: "Create") { [self] name, _ in
            guard let name else { return }
            Task {
                do {
                    try await model.createDirectory(named: name)
                } catch {
                    toast("The directory could not be created", Self.message(error))
                }
            }
        }
    }

    func delete(_ entry: SFTPEntry) {
        Prompts.confirm(in: window, title: "Delete \(entry.path)?", message: entry.isDirectory ? "Everything in it is deleted too." : "",
                        confirm: "Delete", destructive: true) { [self] ok in
            guard ok else { return }
            let client = client
            Task {
                do {
                    if entry.isDirectory {
                        try await client.removeRecursively(entry.path, progress: { _ in }, isCancelled: { false })
                    } else {
                        try await client.removeFile(entry.path)
                    }
                } catch {
                    toast("Could not delete", Self.message(error))
                }
                await model.refresh()
            }
        }
    }

    /// Tabby's "Edit locally": download to a temp folder, open with the default app, and
    /// upload again (keeping the mode) whenever it is saved.
    func editLocally(_ entry: SFTPEntry) {
        guard let name = SFTPPath.safeLocalName(entry.name) else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TabbyMac-SFTP/\(UUID().uuidString)")
        let local = folder.appendingPathComponent(name)
        let client = client
        Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try await client.download(entry.path, to: local, progress: { _ in }, isCancelled: { false })
                NSWorkspace.shared.open(local)
                watch(folder: folder, file: local, remote: entry.path, mode: entry.mode & 0o777)
            } catch {
                toast("Edit locally", Self.message(error))
            }
        }
    }

    /// Editors save by replacing the file, so the folder is watched; changes settle for a
    /// second before the upload. The watcher belongs to the session, not this panel (which
    /// closes on any click in the terminal): it ends when the session does.
    private func watch(folder: URL, file: URL, remote: String, mode: UInt32) {
        var lastModified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let client = client
        let host = host
        let model = model
        LocalEditWatchers.shared.watch(folder: folder, owner: owner) {
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
            guard let modified, modified != lastModified else { return }
            lastModified = modified
            Task { @MainActor in
                let size = Self.localSize(file)
                await TransferCenter.shared.run(name: file.lastPathComponent, direction: .upload, host: host, total: size) { report, cancelled in
                    try await client.upload(file, to: remote, mode: mode == 0 ? 0o644 : mode, progress: report, isCancelled: cancelled)
                }
                await model.refresh()
            }
        }
    }
}
/// "Edit locally" folders watched for saves, by the session they belong to.
@MainActor
final class LocalEditWatchers {
    static let shared = LocalEditWatchers()
    private var sources: [ObjectIdentifier: [DispatchSourceFileSystemObject]] = [:]

    /// Calls `changed` (main queue) a second after the folder's contents settle.
    @discardableResult
    func watch(folder: URL, owner: ObjectIdentifier, changed: @escaping @MainActor () -> Void) -> Bool {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .attrib], queue: .main)
        var pending: DispatchWorkItem?
        source.setEventHandler {
            pending?.cancel()
            let work = DispatchWorkItem { MainActor.assumeIsolated { changed() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[owner, default: []].append(source)
        return true
    }

    func count(owner: ObjectIdentifier) -> Int { sources[owner]?.count ?? 0 }

    /// Stops watching for a session that ended.
    func cancel(owner: ObjectIdentifier) {
        for source in sources.removeValue(forKey: owner) ?? [] { source.cancel() }
    }
}
#endif
