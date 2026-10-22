#if os(macOS)
import CLibSSH
import Foundation
import TabbyCore

extension SSHConnection {
    /// The connection's SFTP session (one per connection, as in Tabby), opened on first use.
    public func sftp() async throws -> SFTPClient {
        try await perform { [self] in
            if let sftpClient { return sftpClient }
            guard let session, let handle = sftp_new(session) else { throw SSHConnectionError.channelFailed(lastError()) }
            guard sftp_init(handle) == SSH_OK else {
                let message = lastError()
                sftp_free(handle)
                throw SSHConnectionError.channelFailed("Could not start SFTP: \(message)")
            }
            let client = SFTPClient(connection: self, handle: handle)
            sftpClient = client
            return client
        }
    }
}

/// SFTP over a connection. Every call runs on the connection's thread; transfers move one
/// 256 KiB chunk per step, so shells and forwards on the same connection keep going.
public final class SFTPClient: @unchecked Sendable {
    public static let chunkSize = 256 * 1024
    unowned let connection: SSHConnection
    private var handle: sftp_session?

    init(connection: SSHConnection, handle: sftp_session) {
        self.connection = connection
        self.handle = handle
    }

    func free() {
        if let handle { sftp_free(handle) }
        handle = nil
    }

    // MARK: Errors

    private func failure(_ action: String, _ path: String) -> SSHConnectionError {
        guard let handle else { return .disconnected }
        let reason: String
        switch Int32(sftp_get_error(handle)) {
        case SSH_FX_NO_SUCH_FILE, SSH_FX_NO_SUCH_PATH: reason = "No such file or directory"
        case SSH_FX_PERMISSION_DENIED: reason = "Permission denied"
        case SSH_FX_FILE_ALREADY_EXISTS: reason = "Already exists"
        case SSH_FX_FAILURE: reason = "The server refused"
        default: reason = connection.lastError()
        }
        return .channelFailed("\(action) \(path): \(reason)")
    }

    private func run<T>(_ work: @escaping (sftp_session) throws -> T) async throws -> T {
        try await connection.perform { [self] in
            guard let handle else { throw SSHConnectionError.disconnected }
            return try work(handle)
        }
    }

    // MARK: Reading

    static func entry(_ a: sftp_attributes, path: String) -> SFTPEntry {
        let type = a.pointee.type
        let mode = a.pointee.permissions
        let isLink = type == UInt8(SSH_FILEXFER_TYPE_SYMLINK) || mode & 0o170000 == 0o120000
        let isDirectory = !isLink && (type == UInt8(SSH_FILEXFER_TYPE_DIRECTORY) || mode & 0o170000 == 0o040000)
        let seconds = a.pointee.mtime64 > 0 ? TimeInterval(a.pointee.mtime64) : TimeInterval(a.pointee.mtime)
        return SFTPEntry(name: a.pointee.name.map { String(cString: $0) } ?? (path as NSString).lastPathComponent, path: path,
                         isDirectory: isDirectory, isSymlink: isLink, mode: mode, size: a.pointee.size,
                         modified: Date(timeIntervalSince1970: seconds))
    }

    /// A directory's entries (without `.` and `..`), unsorted.
    public func list(_ path: String) async throws -> [SFTPEntry] {
        try await run { [self] handle in
            guard let dir = sftp_opendir(handle, path) else { throw failure("Cannot open", path) }
            defer { sftp_closedir(dir) }
            var entries: [SFTPEntry] = []
            while let attributes = sftp_readdir(handle, dir) {
                defer { sftp_attributes_free(attributes) }
                let name = attributes.pointee.name.map { String(cString: $0) } ?? ""
                guard name != ".", name != "..", !name.isEmpty else { continue }
                entries.append(Self.entry(attributes, path: SFTPPath.join(path, name)))
            }
            guard sftp_dir_eof(dir) != 0 else { throw failure("Cannot read", path) }
            return entries
        }
    }

    /// Follows symlinks.
    public func stat(_ path: String) async throws -> SFTPEntry {
        try await run { [self] handle in
            guard let attributes = sftp_stat(handle, path) else { throw failure("Cannot read", path) }
            defer { sftp_attributes_free(attributes) }
            var entry = Self.entry(attributes, path: path)
            entry.name = (path as NSString).lastPathComponent
            return entry
        }
    }

    public func readLink(_ path: String) async throws -> String {
        try await run { [self] handle in
            guard let target = sftp_readlink(handle, path) else { throw failure("Cannot read the link", path) }
            defer { ssh_string_free_char(target) }
            return String(cString: target)
        }
    }

    /// The server's absolute form of `path` (`.` is the home folder).
    public func canonicalPath(_ path: String) async throws -> String {
        try await run { [self] handle in
            guard let resolved = sftp_canonicalize_path(handle, path) else { throw failure("Cannot resolve", path) }
            defer { ssh_string_free_char(resolved) }
            return String(cString: resolved)
        }
    }

    // MARK: Changing

    public func makeDirectory(_ path: String, mode: UInt32 = 0o755) async throws {
        try await run { [self] handle in
            guard sftp_mkdir(handle, path, mode_t(mode)) == 0 else { throw failure("Cannot create", path) }
        }
    }

    public func removeDirectory(_ path: String) async throws {
        try await run { [self] handle in
            guard sftp_rmdir(handle, path) == 0 else { throw failure("Cannot delete", path) }
        }
    }

    public func removeFile(_ path: String) async throws {
        try await run { [self] handle in
            guard sftp_unlink(handle, path) == 0 else { throw failure("Cannot delete", path) }
        }
    }

    public func rename(_ path: String, to newPath: String) async throws {
        try await run { [self] handle in
            guard sftp_rename(handle, path, newPath) == 0 else { throw failure("Cannot rename", path) }
        }
    }

    public func setMode(_ path: String, _ mode: UInt32) async throws {
        try await run { [self] handle in
            guard sftp_chmod(handle, path, mode_t(mode)) == 0 else { throw failure("Cannot change", path) }
        }
    }

    /// Deletes a folder and everything in it, each removal awaited (Tabby's didn't wait for
    /// its unlinks). Symlinks are removed, not followed.
    public func removeRecursively(_ path: String, progress: (String) -> Void, isCancelled: () -> Bool) async throws {
        for entry in try await list(path) {
            guard !isCancelled() else { throw SSHConnectionError.cancelled }
            if entry.isDirectory {
                try await removeRecursively(entry.path, progress: progress, isCancelled: isCancelled)
            } else {
                try await removeFile(entry.path)
                progress(entry.path)
            }
        }
        try await removeDirectory(path)
        progress(path)
    }

    // MARK: Transfers

    private final class RemoteFile: @unchecked Sendable {
        let file: sftp_file
        init(_ file: sftp_file) { self.file = file }
    }

    /// Downloads to `local` (replaced); a cancelled or failed download removes the partial file.
    public func download(_ path: String, to local: URL, progress: (UInt64) -> Void, isCancelled: () -> Bool) async throws {
        let remote = try await run { [self] handle -> RemoteFile in
            guard let file = sftp_open(handle, path, O_RDONLY, 0) else { throw failure("Cannot open", path) }
            return RemoteFile(file)
        }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: local) else {
            _ = try? await run { _ in sftp_close(remote.file) }
            throw SSHConnectionError.channelFailed("Cannot write \(local.path)")
        }
        do {
            while true {
                guard !isCancelled() else { throw SSHConnectionError.cancelled }
                let chunk = try await run { [self] _ -> Data in
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 65_536)
                    while data.count < Self.chunkSize {
                        let n = sftp_read(remote.file, &buffer, buffer.count)
                        if n < 0 { throw failure("Cannot read", path) }
                        if n == 0 { break }
                        data.append(contentsOf: buffer[0..<n])
                    }
                    return data
                }
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                progress(UInt64(chunk.count))
            }
            try output.close()
            _ = try await run { _ in sftp_close(remote.file) }
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: local)
            _ = try? await run { _ in sftp_close(remote.file) }
            throw error
        }
    }

    /// Uploads to `<path>.tabby-upload`, then replaces `path` with it (Tabby); a cancelled or
    /// failed upload removes the temp file and leaves `path` as it was.
    public func upload(_ local: URL, to path: String, mode: UInt32 = 0o644, progress: (UInt64) -> Void,
                       isCancelled: () -> Bool) async throws {
        guard let input = try? FileHandle(forReadingFrom: local) else {
            throw SSHConnectionError.channelFailed("Cannot read \(local.path)")
        }
        defer { try? input.close() }
        let temporary = path + ".tabby-upload"
        let remote = try await run { [self] handle -> RemoteFile in
            guard let file = sftp_open(handle, temporary, O_WRONLY | O_CREAT | O_TRUNC, mode_t(mode)) else {
                throw failure("Cannot create", temporary)
            }
            return RemoteFile(file)
        }
        do {
            while true {
                guard !isCancelled() else { throw SSHConnectionError.cancelled }
                guard let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                try await run { [self] _ in
                    try chunk.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = sftp_write(remote.file, raw.baseAddress! + offset, raw.count - offset)
                            guard n > 0 else { throw failure("Cannot write", temporary) }
                            offset += n
                        }
                    }
                }
                progress(UInt64(chunk.count))
            }
            try await run { [self] handle in
                sftp_close(remote.file)
                if let existing = sftp_lstat(handle, path) {
                    sftp_attributes_free(existing)
                    guard sftp_unlink(handle, path) == 0 else { throw failure("Cannot replace", path) }
                }
                guard sftp_rename(handle, temporary, path) == 0 else { throw failure("Cannot rename", temporary) }
            }
        } catch {
            _ = try? await run { handle in
                sftp_close(remote.file)
                sftp_unlink(handle, temporary)
            }
            throw error
        }
    }
}
#endif
