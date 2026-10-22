import Foundation

/// One private key that arrived through sync.
public struct KeyFileRecord: Codable, Hashable, Sendable {
    /// SHA-512 of the contents (Tabby's key-passphrase id).
    public var id: String
    /// The path the key had on the Mac it came from, as the profile names it (`~/.ssh/x`).
    public var originalPath: String
    /// One of ssh's default identities (`~/.ssh/id_ed25519`, …), used by profiles that name no key.
    public var isDefaultIdentity: Bool
}

/// Synced private keys under `<config>/keys/<id>` (owner-only), with an index by original
/// path. Profiles keep their paths; `SyncedKeys` swaps in the synced copy when a key file is
/// missing on this Mac.
public final class KeyFileStore: @unchecked Sendable {
    public let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public init(directory: URL) {
        self.directory = directory
    }

    public func records() -> [KeyFileRecord] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([KeyFileRecord].self, from: data)) ?? []
    }

    public func path(for id: String) -> String { directory.appendingPathComponent(id).path }

    /// A key id is the lowercase hex SHA-512 of the key file; it names the stored file.
    public static func isValidID(_ id: String) -> Bool {
        id.utf8.count == 128 && id.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public func store(id: String, originalPath: String, contents: Data, isDefaultIdentity: Bool) throws {
        guard Self.isValidID(id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = path(for: id)
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: contents, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var list = records().filter { $0.id != id }
        list.append(KeyFileRecord(id: id, originalPath: originalPath, isDefaultIdentity: isDefaultIdentity))
        try save(list)
    }

    public func remove(id: String) {
        guard Self.isValidID(id) else { return }
        try? FileManager.default.removeItem(atPath: path(for: id))
        try? save(records().filter { $0.id != id })
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    public func syncedKeys() -> SyncedKeys {
        var byPath: [String: String] = [:]
        var defaults: [(original: String, stored: String)] = []
        for r in records() {
            byPath[SyncedKeys.normalize(r.originalPath)] = path(for: r.id)
            if r.isDefaultIdentity { defaults.append((SyncedKeys.normalize(r.originalPath), path(for: r.id))) }
        }
        return SyncedKeys(storedByPath: byPath, defaultIdentities: defaults.map { [$0.original, $0.stored] })
    }

    private func save(_ list: [KeyFileRecord]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: indexURL, options: .atomic)
    }
}

/// Resolves profile key paths against the synced keys (see `KeyFileStore`).
public struct SyncedKeys: Equatable, Sendable {
    /// Normalised original path → stored file.
    public var storedByPath: [String: String]
    /// `[original, stored]` pairs of synced default identities.
    public var defaultIdentities: [[String]]

    public static let none = SyncedKeys(storedByPath: [:], defaultIdentities: [])
    /// ssh's default identity files, in the order it tries them.
    public static let defaultIdentityNames = ["id_rsa", "id_ecdsa", "id_ecdsa_sk", "id_ed25519", "id_ed25519_sk", "id_xmss", "id_dsa"]

    public init(storedByPath: [String: String], defaultIdentities: [[String]]) {
        self.storedByPath = storedByPath
        self.defaultIdentities = defaultIdentities
    }

    /// Expands `~/` and `file://` the way the config generator does.
    public static func normalize(_ key: String) -> String {
        if key.hasPrefix("file://"), let url = URL(string: key) { return url.path }
        if key.hasPrefix("~/") { return NSHomeDirectory() + String(key.dropFirst(1)) }
        return key
    }

    /// The key path itself when the file exists here, otherwise its synced copy if there is one.
    public func resolve(_ key: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let normalized = Self.normalize(key)
        if fileExists(normalized) { return key }
        return storedByPath[normalized] ?? key
    }

    /// For a profile that names no key: ssh's local default identities plus synced ones whose
    /// local file is missing. Empty when nothing was synced, so ssh keeps its own defaults.
    /// Local defaults must be listed too: naming any IdentityFile stops ssh trying them.
    public func identitiesForProfileWithoutKeys(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        let synced = defaultIdentities.filter { !fileExists($0[0]) }.map { $0[1] }
        guard !synced.isEmpty else { return [] }
        let local = Self.defaultIdentityNames.map { NSHomeDirectory() + "/.ssh/" + $0 }.filter(fileExists)
        return local + synced
    }
}
