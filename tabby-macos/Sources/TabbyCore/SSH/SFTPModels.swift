import Foundation

/// One row of an SFTP listing.
public struct SFTPEntry: Equatable, Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var isSymlink: Bool
    public var mode: UInt32
    public var size: UInt64
    public var modified: Date

    public init(name: String, path: String, isDirectory: Bool, isSymlink: Bool, mode: UInt32, size: UInt64, modified: Date) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.mode = mode
        self.size = size
        self.modified = modified
    }

    /// Directories first, then by name the way Finder orders them (case-insensitive,
    /// numbers by value).
    public static func sorted(_ list: [SFTPEntry]) -> [SFTPEntry] {
        list.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.compare(b.name, options: [.caseInsensitive, .numeric]) == .orderedAscending
        }
    }

    /// Tabby's filter: names containing the text, ignoring case; blank shows everything.
    public static func filtered(_ list: [SFTPEntry], by text: String) -> [SFTPEntry] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(needle) }
    }

    /// Tabby's mode column, template `SGdrwxrwxrwx` (S setuid, G setgid, d directory).
    public static func modeString(_ mode: UInt32) -> String {
        let shown = Array("SGdrwxrwxrwx")
        let hidden = Array("   ---------")
        let isDirectory = mode & 0o170000 == 0o040000
        let bits: [Bool] = [mode & 0o4000 != 0, mode & 0o2000 != 0, isDirectory] + (0..<9).map { mode & (0o400 >> UInt32($0)) != 0 }
        return String(bits.enumerated().map { $0.element ? shown[$0.offset] : hidden[$0.offset] })
    }
}

/// Remote (POSIX) paths for the SFTP panel, always absolute.
public enum SFTPPath {
    public static func join(_ directory: String, _ name: String) -> String {
        normalize(directory + "/" + name)
    }

    public static func parent(_ path: String) -> String {
        let parts = components(path)
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// Collapses `//`, `.` and `..`; `..` above the root stays at the root.
    public static func normalize(_ path: String) -> String {
        "/" + components(path).joined(separator: "/")
    }

    /// One crumb per component, each with the path it opens.
    public static func breadcrumb(_ path: String) -> [(name: String, path: String)] {
        let parts = components(path)
        return parts.indices.map { (parts[$0], "/" + parts[...$0].joined(separator: "/")) }
    }

    /// A remote name used as a local file or folder name: refused when it could leave the
    /// destination folder (`..`, `/`) or is empty.
    public static func safeLocalName(_ name: String) -> String? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return name
    }

    /// `name`, or `name (1)`, `name (2)`, … when taken (Tabby's folder download).
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        var counter = 1
        while exists("\(name) (\(counter))") { counter += 1 }
        return "\(name) (\(counter))"
    }

    private static func components(_ path: String) -> [String] {
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": _ = result.popLast()
            default: result.append(String(part))
            }
        }
        return result
    }
}

/// Bytes moved and speed of one transfer; the speed is the last chunk's, as in Tabby.
public struct TransferProgress: Equatable, Sendable {
    public private(set) var total: UInt64
    public private(set) var completed: UInt64 = 0
    public private(set) var bytesPerSecond: Double = 0
    private var lastChunkAt: Date

    public init(total: UInt64, start: Date) {
        self.total = total
        lastChunkAt = start
    }

    public var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }
    public var isComplete: Bool { total > 0 && completed >= total }

    public mutating func record(bytes: UInt64, at time: Date) {
        completed += bytes
        let elapsed = time.timeIntervalSince(lastChunkAt)
        if elapsed > 0 { bytesPerSecond = Double(bytes) / elapsed }
        lastChunkAt = time
    }

    /// For transfers whose size is learned late (folders).
    public mutating func setTotal(_ total: UInt64) {
        self.total = total
    }
}
