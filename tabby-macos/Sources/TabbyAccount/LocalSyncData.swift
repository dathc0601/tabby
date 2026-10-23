import Crypto
import Foundation
import TabbyCore
import TabbySSH
import TabbySyncProtocol

/// What the user chose to sync (`account.parts.*`, all on by default).
public struct SyncParts: Equatable, Sendable {
    public var profiles = true
    public var secrets = true
    public var knownHosts = true
    public var settings = true

    public init(config: ConfigStore) {
        profiles = config.value("account.parts.profiles")?.boolValue ?? true
        secrets = config.value("account.parts.secrets")?.boolValue ?? true
        knownHosts = config.value("account.parts.knownHosts")?.boolValue ?? true
        settings = config.value("account.parts.settings")?.boolValue ?? true
    }
}

/// A private key file that could be uploaded but has not been approved or declined yet.
public struct KeyFileCandidate: Hashable, Sendable, Identifiable {
    /// SHA-512 of the contents, as `SSHSession.keyID` computes it.
    public var id: String
    /// The path as the profile names it, or `~/.ssh/<name>` for ssh's default identities.
    public var originalPath: String
    public var isDefaultIdentity: Bool

    public init(id: String, originalPath: String, isDefaultIdentity: Bool) {
        self.id = id
        self.originalPath = originalPath
        self.isDefaultIdentity = isDefaultIdentity
    }
}

/// This Mac's syncable data: user profiles and groups, SSH passwords and key passphrases in
/// the Keychain, private key files, TabbyMac's known_hosts and the rest of the settings.
/// `collect` reads it, `apply` writes a merged snapshot back. Only main-actor code touches
/// the config.
@MainActor
public final class LocalSyncData {
    public let config: ConfigStore
    public let passwords: PasswordStore
    public let keyStore: KeyFileStore
    public let knownHostsFile: URL
    public let homeDirectory: String

    /// Settings that stay on this Mac (the rest of the user config syncs).
    static let localOnlySettings: [[String]] = [["profiles"], ["groups"], ["account"], ["appearance", "dockScreen"]]

    public init(config: ConfigStore, passwords: PasswordStore, keyStore: KeyFileStore, knownHostsFile: URL,
                homeDirectory: String = NSHomeDirectory()) {
        self.config = config
        self.passwords = passwords
        self.keyStore = keyStore
        self.knownHostsFile = knownHostsFile
        self.homeDirectory = homeDirectory
    }

    public static func keyID(_ contents: Data) -> String {
        SHA512.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    }

    struct Collected {
        var profiles: [(String, JSONValue)] = []
        var groups: [(String, JSONValue)] = []
        var settings: String?
        var secrets: [(String, JSONValue)] = []
        var keyFiles: [(String, JSONValue)] = []
        var knownHostLines: [(String, JSONValue)] = []
        /// Every key file found here, approved or not, by id (so a synced copy isn't stored twice).
        var localKeyIDs: Set<String> = []
        var pendingKeyFiles: [KeyFileCandidate] = []
        /// Sections that could not be read completely (a locked keychain, a denied prompt, an
        /// unreadable file). Their missing items must not become deletions.
        var incomplete: Set<String> = []

        func ids(_ section: String) -> [String: JSONValue] {
            let list: [(String, JSONValue)]
            switch section {
            case "profiles": list = profiles
            case "groups": list = groups
            case "secrets": list = secrets
            case "keyFiles": list = keyFiles
            case "knownHostLines": list = knownHostLines
            default: list = []
            }
            return Dictionary(list, uniquingKeysWith: { a, _ in a })
        }
    }

    // MARK: Conversions

    static func json(_ value: ConfigValue) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return v
    }

    static func config(_ value: JSONValue) -> ConfigValue {
        guard let data = try? JSONEncoder().encode(value), let v = try? JSONDecoder().decode(ConfigValue.self, from: data) else { return .null }
        return v
    }

    static func canonicalJSON(_ value: JSONValue) -> String {
        (try? SyncCoding.encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    // MARK: Collect

    /// - Parameter accountKeyIDs: key files already in the account; a local copy of one of
    ///   them is included even if the user declined uploading it from here.
    func collect(recoveryKey: String?, accountKeyIDs: Set<String> = []) -> Collected {
        var c = Collected()
        func list(_ key: String) -> [(String, JSONValue)] {
            (config.user[key]?.arrayValue ?? []).compactMap { item in item["id"]?.stringValue.map { ($0, Self.json(item)) } }
        }
        c.profiles = list("profiles")
        c.groups = list("groups")

        var settings = config.user
        for path in Self.localOnlySettings { settings.setValue(nil, at: path) }
        c.settings = Self.canonicalJSON(Self.json(settings))

        let saved: [SavedSecret]
        do {
            saved = try passwords.savedSecrets()
        } catch {
            saved = []
            c.incomplete.insert("secrets")
        }
        for secret in saved {
            switch secret {
            case let .password(host, port, user):
                guard let value = passwords.password(host: host, port: port, user: user) else {
                    c.incomplete.insert("secrets")
                    continue
                }
                c.secrets.append(("ssh:password|\(host)|\(port)|\(user)", .object([
                    "type": .string("ssh:password"), "host": .string(host), "port": .number(Double(port)),
                    "user": .string(user), "value": .string(value),
                ])))
            case let .passphrase(keyID):
                guard let value = passwords.passphrase(keyID: keyID) else {
                    c.incomplete.insert("secrets")
                    continue
                }
                c.secrets.append(("ssh:key-passphrase|\(keyID)", .object([
                    "type": .string("ssh:key-passphrase"), "keyID": .string(keyID), "value": .string(value),
                ])))
            }
        }
        if let recoveryKey {
            c.secrets.append(("account:recovery-key", .object(["type": .string("account:recovery-key"), "value": .string(recoveryKey)])))
        }
        c.secrets.sort { $0.0 < $1.0 }

        collectKeyFiles(into: &c, accountKeyIDs: accountKeyIDs)
        if FileManager.default.fileExists(atPath: knownHostsFile.path) {
            if let text = try? String(contentsOf: knownHostsFile, encoding: .utf8) {
                c.knownHostLines = Self.lines(text).map { (Self.lineID($0), .string($0)) }
            } else {
                c.incomplete.insert("knownHostLines")
            }
        }
        return c
    }

    static func lines(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && seen.insert($0).inserted }
    }

    static func lineID(_ line: String) -> String {
        SHA256.hash(data: Data(line.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A cheap summary of what `collect` would read (no secret values), to notice a change made
    /// while a sync waits for the server.
    func fingerprint() -> String {
        var parts = [Self.canonicalJSON(Self.json(config.user))]
        parts.append((try? String(contentsOf: knownHostsFile, encoding: .utf8)) ?? "")
        parts.append(keyStore.records().map(\.id).sorted().joined(separator: ","))
        let names = ((try? passwords.savedSecrets()) ?? []).map { "\($0)" }.sorted()
        parts.append(names.joined(separator: ","))
        return ChangeTracker.hash(parts.joined(separator: "\u{0}"))
    }

    private func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return homeDirectory + String(path.dropFirst(1)) }
        return SyncedKeys.normalize(path)
    }

    private func collectKeyFiles(into c: inout Collected, accountKeyIDs: Set<String>) {
        let approved = Set(config.value("account.approvedKeyFiles")?.stringArrayValue ?? [])
        let declined = Set(config.value("account.declinedKeyFiles")?.stringArrayValue ?? [])
        var candidates: [(path: String, isDefault: Bool)] = []
        for profile in config.user["profiles"]?.arrayValue ?? [] {
            for key in profile["options"]?["privateKeys"]?.stringArrayValue ?? [] { candidates.append((key, false)) }
        }
        for name in SyncedKeys.defaultIdentityNames { candidates.append(("~/.ssh/\(name)", true)) }

        var seen = Set<String>()
        func add(id: String, originalPath: String, isDefault: Bool, contents: Data) {
            guard !seen.contains(id) else { return }
            seen.insert(id)
            c.keyFiles.append((id, .object([
                "originalPath": .string(originalPath), "isDefaultIdentity": .bool(isDefault),
                "contents": .string(contents.base64EncodedString()),
            ])))
        }
        for (path, isDefault) in candidates {
            guard let contents = FileManager.default.contents(atPath: expand(path)) else { continue }
            let id = Self.keyID(contents)
            c.localKeyIDs.insert(id)
            if approved.contains(id) || accountKeyIDs.contains(id) {
                add(id: id, originalPath: path, isDefault: isDefault, contents: contents)
            } else if !declined.contains(id), !c.pendingKeyFiles.contains(where: { $0.id == id }) {
                c.pendingKeyFiles.append(KeyFileCandidate(id: id, originalPath: path, isDefaultIdentity: isDefault))
            }
        }
        // Keys that arrived through sync stay in the vault while they are here.
        for record in keyStore.records() {
            guard let contents = FileManager.default.contents(atPath: keyStore.path(for: record.id)) else {
                c.incomplete.insert("keyFiles")
                continue
            }
            add(id: record.id, originalPath: record.originalPath, isDefault: record.isDefaultIdentity, contents: contents)
        }
    }

    // MARK: Apply

    /// Writes what other Macs changed. Sections that could not be read completely here, and
    /// parts that are off, are left alone.
    func apply(_ merged: SyncSnapshot, over local: Collected, parts: SyncParts) {
        let skip = local.incomplete
        if parts.profiles {
            applyList("profiles", merged.profiles, local.profiles)
            applyList("groups", merged.groups, local.groups)
        }
        if parts.settings, let text = merged.settings?.text, text != local.settings,
           let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            var user = Self.config(value)
            if user.objectValue == nil { user = .emptyObject }
            for path in Self.localOnlySettings {
                user.setValue(config.user.value(at: path), at: path)
            }
            try? config.replaceUser(user)
        }
        if parts.secrets {
            if !skip.contains("secrets") { applySecrets(merged.secrets, local.secrets) }
            if !skip.contains("keyFiles") { applyKeyFiles(merged.keyFiles, localIDs: local.localKeyIDs) }
        }
        if parts.knownHosts, !skip.contains("knownHostLines") {
            let lines = merged.knownHostLines.items.compactMap(\.value.stringValue)
            if lines != local.knownHostLines.compactMap(\.1.stringValue) {
                try? FileManager.default.createDirectory(at: knownHostsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").write(to: knownHostsFile, atomically: true, encoding: .utf8)
            }
        }
    }

    private func applyList(_ key: String, _ merged: ItemSection, _ local: [(String, JSONValue)]) {
        let current = local.map(\.1)
        let new = merged.items.map(\.value)
        guard new != current else { return }
        config.set(key, new.isEmpty ? nil : .array(new.map(Self.config)))
    }

    private func applySecrets(_ merged: ItemSection, _ local: [(String, JSONValue)]) {
        let localValues = Dictionary(local, uniquingKeysWith: { a, _ in a })
        for item in merged.items where localValues[item.id] != item.value {
            write(secret: item.value)
        }
        // Only what the account deleted (a tombstone) is deleted here.
        let deleted = Set(merged.deleted.map(\.id))
        for (id, value) in local where deleted.contains(id) {
            delete(secret: value)
        }
    }

    private func write(secret v: JSONValue) {
        guard let value = v["value"]?.stringValue else { return }
        switch v["type"]?.stringValue {
        case "ssh:password":
            guard let host = v["host"]?.stringValue, let user = v["user"]?.stringValue else { return }
            passwords.savePassword(value, host: host, port: Int(v["port"]?.doubleValue ?? 0), user: user)
        case "ssh:key-passphrase":
            if let id = v["keyID"]?.stringValue { passwords.savePassphrase(value, keyID: id) }
        default:
            break // the recovery key lives in the session, see SyncEngine
        }
    }

    private func delete(secret v: JSONValue) {
        switch v["type"]?.stringValue {
        case "ssh:password":
            guard let host = v["host"]?.stringValue, let user = v["user"]?.stringValue else { return }
            passwords.deletePassword(host: host, port: Int(v["port"]?.doubleValue ?? 0), user: user)
        case "ssh:key-passphrase":
            if let id = v["keyID"]?.stringValue { passwords.deletePassphrase(keyID: id) }
        default:
            break
        }
    }

    private func applyKeyFiles(_ merged: ItemSection, localIDs: Set<String>) {
        let stored = Set(keyStore.records().map(\.id))
        for item in merged.items where !localIDs.contains(item.id) && !stored.contains(item.id) {
            guard let path = item.value["originalPath"]?.stringValue,
                  let contents = item.value["contents"]?.stringValue.flatMap({ Data(base64Encoded: $0) }),
                  Self.keyID(contents) == item.id else { continue }
            try? keyStore.store(id: item.id, originalPath: path, contents: contents,
                                isDefaultIdentity: item.value["isDefaultIdentity"]?.boolValue ?? false)
        }
        // Only synced copies are removed; the user's own files in ~/.ssh are never touched.
        for tombstone in merged.deleted where stored.contains(tombstone.id) {
            keyStore.remove(id: tombstone.id)
        }
    }

    /// Removes everything that came from the account (sign out › "Remove synced data").
    func remove(_ snapshot: SyncSnapshot) {
        remove(profileIDs: Set(snapshot.profiles.items.map(\.id)), groupIDs: Set(snapshot.groups.items.map(\.id)),
               secretIDs: snapshot.secrets.items.map(\.id))
    }

    /// The same by ids, as the change tracker remembers them after a relaunch.
    /// Key files copied here from the account (`<config>/keys`).
    var syncedKeyCount: Int { keyStore.records().count }

    func remove(profileIDs: Set<String>, groupIDs: Set<String>, secretIDs: [String]) {
        let keep = { (key: String, ids: Set<String>) in
            let list = (self.config.user[key]?.arrayValue ?? []).filter { !ids.contains($0["id"]?.stringValue ?? "") }
            self.config.set(key, list.isEmpty ? nil : .array(list))
        }
        keep("profiles", profileIDs)
        keep("groups", groupIDs)
        for id in secretIDs {
            let parts = id.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if parts.first == "ssh:password", parts.count == 4, let port = Int(parts[2]) {
                passwords.deletePassword(host: parts[1], port: port, user: parts[3])
            } else if parts.first == "ssh:key-passphrase", parts.count == 2 {
                passwords.deletePassphrase(keyID: parts[1])
            }
        }
        keyStore.removeAll()
    }
}
