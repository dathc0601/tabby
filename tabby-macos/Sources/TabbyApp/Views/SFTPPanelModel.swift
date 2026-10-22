#if canImport(AppKit)
import Foundation
import Observation
import TabbyCore
import TabbySSHLib

/// What the SFTP panel needs from a server (SFTPClient; a fake in tests).
protocol SFTPBrowsing: AnyObject {
    func list(_ path: String) async throws -> [SFTPEntry]
    func stat(_ path: String) async throws -> SFTPEntry
    func readLink(_ path: String) async throws -> String
    func makeDirectory(_ path: String, mode: UInt32) async throws
}

/// Transfers and deletes on top of browsing (the panel's controller).
protocol SFTPOperations: SFTPBrowsing {
    func download(_ path: String, to local: URL, progress: (UInt64) -> Void, isCancelled: () -> Bool) async throws
    func upload(_ local: URL, to path: String, mode: UInt32, progress: (UInt64) -> Void, isCancelled: () -> Bool) async throws
    func removeFile(_ path: String) async throws
    func removeRecursively(_ path: String, progress: (String) -> Void, isCancelled: () -> Bool) async throws
}

extension SFTPClient: SFTPOperations {}

/// The SFTP panel's state (Tabby's `SFTPPanelComponent`): the current folder, sorted and
/// filtered entries, the breadcrumb.
@Observable
@MainActor
final class SFTPPanelModel {
    enum Action: Equatable {
        case download(SFTPEntry)
    }

    let host: String
    let client: SFTPBrowsing
    private(set) var path = "/"
    private var listing: [SFTPEntry] = []
    private var hasOpenedAFolder = false
    var filterText = ""
    var showsFilter = false
    private(set) var isLoading = false
    private(set) var error: String?

    init(host: String, client: SFTPBrowsing) {
        self.host = host
        self.client = client
    }

    /// Where the panel opens: the shell's reported folder, else where it was last, else `/`.
    static func startPath(shellDirectory: String?, last: String?) -> String {
        shellDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? last ?? "/"
    }

    var entries: [SFTPEntry] { SFTPEntry.sorted(SFTPEntry.filtered(listing, by: filterText)) }
    var breadcrumb: [(name: String, path: String)] { SFTPPath.breadcrumb(path) }
    var canGoUp: Bool { path != "/" && filterText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Shown instead of the list when the filter hides everything.
    var emptyMessage: String? {
        let text = filterText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, entries.isEmpty, !listing.isEmpty else { return nil }
        return "No files match the filter “\(text)”"
    }

    func navigate(to newPath: String) async {
        let target = SFTPPath.normalize(newPath)
        isLoading = true
        defer { isLoading = false }
        do {
            listing = try await client.list(target)
            path = target
            filterText = ""
            error = nil
            hasOpenedAFolder = true
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // The first folder could not be opened: show the root instead (Tabby).
            if !hasOpenedAFolder, target != "/" {
                let message = self.error
                await navigate(to: "/")
                self.error = message
            }
        }
    }

    func refresh() async {
        await navigate(to: path)
    }

    func goUp() async {
        await navigate(to: SFTPPath.parent(path))
    }

    /// A folder opens; a link is followed (opening at the link's own path, as Tabby does); a
    /// file is for downloading.
    func open(_ entry: SFTPEntry) async -> Action? {
        if entry.isDirectory {
            await navigate(to: entry.path)
            return nil
        }
        if entry.isSymlink {
            do {
                let target = try await client.stat(entry.path)
                if target.isDirectory {
                    await navigate(to: entry.path)
                    return nil
                }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                return nil
            }
        }
        return .download(entry)
    }

    struct InvalidName: LocalizedError {
        var errorDescription: String? { "A folder name cannot be empty or contain “/”." }
    }

    /// Creates a folder here and opens it (Tabby).
    func createDirectory(named name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard SFTPPath.safeLocalName(trimmed) != nil else { throw InvalidName() }
        let newPath = SFTPPath.join(path, trimmed)
        try await client.makeDirectory(newPath, mode: 0o755)
        await navigate(to: newPath)
    }
}
#endif
