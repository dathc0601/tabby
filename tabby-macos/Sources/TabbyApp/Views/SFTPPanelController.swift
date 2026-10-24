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
                    symbol: "folder", tint: .danger, title: L("SFTP"), detail: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
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
        panel.prompt = L("Download here")
        panel.message = L("Select destination folder for {name}", ["name": entry.name])
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
        panel.prompt = L("Upload")
        panel.beginSheetModal(for: window ?? NSWindow()) { [self] response in
            guard response == .OK else { return }
            upload(panel.urls)
        }
    }

    func chooseFolderToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = L("Upload")
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
        Prompts.text(in: window, title: L("Name for the new directory"), confirm: L("Create")) { [self] name, _ in
            guard let name else { return }
            Task {
                do {
                    try await model.createDirectory(named: name)
                } catch {
                    toast(L("The directory could not be created"), Self.message(error))
                }
            }
        }
    }

    func delete(_ entry: SFTPEntry) {
        Prompts.confirm(in: window, title: L("Delete {path}?", ["path": entry.path]), message: entry.isDirectory ? L("Everything in it is deleted too.") : "",
                        confirm: L("Delete"), destructive: true) { [self] ok in
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
                    toast(L("Could not delete"), Self.message(error))
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
                toast(L("Edit locally"), Self.message(error))
            }
        }
    }

    /// Saves are watched whether the editor replaces the file or writes into it; changes
    /// settle for a second before the upload. The watcher belongs to the session, not this
    /// panel (which closes on any click in the terminal): it ends when the session does.
    private func watch(folder: URL, file: URL, remote: String, mode: UInt32) {
        var lastModified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        let client = client
        let host = host
        let model = model
        LocalEditWatchers.shared.watch(folder: folder, file: file, owner: owner) {
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
/// "Edit locally" files watched for saves, by the session they belong to.
@MainActor
final class LocalEditWatchers {
    static let shared = LocalEditWatchers()
    private var watches: [ObjectIdentifier: [Watch]] = [:]

    /// One edited file. Its folder is watched for editors that save by replacing the file
    /// (TextEdit), the file itself for writes in place (a shell `>>`, editors that overwrite;
    /// found in the M8 walk), and the file again after each replace, since its watch followed
    /// the old one.
    @MainActor
    private final class Watch {
        let file: URL
        let changed: @MainActor () -> Void
        var folderSource: DispatchSourceFileSystemObject?
        var fileSource: DispatchSourceFileSystemObject?
        var pending: DispatchWorkItem?
        var isCancelled = false

        init(file: URL, changed: @escaping @MainActor () -> Void) {
            self.file = file
            self.changed = changed
        }

        /// Calls `changed` a second after the changes settle.
        func noticed() {
            guard !isCancelled else { return }
            pending?.cancel()
            let changed = changed
            let work = DispatchWorkItem { MainActor.assumeIsolated { changed() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
        }

        func watchFile() {
            fileSource?.cancel()
            fileSource = nil
            guard !isCancelled,
                  let source = LocalEditWatchers.source(file.path, events: [.write, .extend, .attrib, .rename, .delete]) else { return }
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.fileSource?.data.contains(.rename) == true || self.fileSource?.data.contains(.delete) == true {
                        self.watchFile()
                    }
                    self.noticed()
                }
            }
            source.resume()
            fileSource = source
        }

        func cancel() {
            isCancelled = true
            pending?.cancel()
            folderSource?.cancel()
            fileSource?.cancel()
        }
    }

    /// Calls `changed` (main queue) a second after `file`'s changes settle.
    @discardableResult
    func watch(folder: URL, file: URL, owner: ObjectIdentifier, changed: @escaping @MainActor () -> Void) -> Bool {
        guard let folderSource = Self.source(folder.path, events: [.write, .rename, .attrib]) else { return false }
        let watch = Watch(file: file, changed: changed)
        folderSource.setEventHandler { [weak watch] in
            MainActor.assumeIsolated {
                guard let watch else { return }
                // Something in the folder changed: perhaps a new file under the same name.
                watch.watchFile()
                watch.noticed()
            }
        }
        folderSource.resume()
        watch.folderSource = folderSource
        watch.watchFile()
        watches[owner, default: []].append(watch)
        return true
    }

    nonisolated fileprivate static func source(_ path: String, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setCancelHandler { close(fd) }
        return source
    }

    func count(owner: ObjectIdentifier) -> Int { watches[owner]?.count ?? 0 }

    /// Stops watching for a session that ended.
    func cancel(owner: ObjectIdentifier) {
        for watch in watches.removeValue(forKey: owner) ?? [] { watch.cancel() }
    }
}
#endif
