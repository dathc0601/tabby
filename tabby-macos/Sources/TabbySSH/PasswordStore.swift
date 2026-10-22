import Foundation
import TabbyCore
#if canImport(Security)
import Security
#endif

/// Saved SSH secrets. Item naming matches Tabby's keytar usage
/// (`tabby-ssh/src/services/passwordStorage.service.ts`): service `ssh@host:port`,
/// account = user name; key passphrases use service `ssh-private-key:<id>`.
public protocol PasswordStore: AnyObject {
    func password(host: String, port: Int, user: String) -> String?
    /// Whether a password is saved, without reading it (reading can raise a Keychain prompt).
    func hasPassword(host: String, port: Int, user: String) -> Bool
    func savePassword(_ password: String, host: String, port: Int, user: String)
    func deletePassword(host: String, port: Int, user: String)
    func passphrase(keyID: String) -> String?
    func savePassphrase(_ passphrase: String, keyID: String)
    func deletePassphrase(keyID: String)
    /// What is saved, by name only (sync uploads these; listing never reads a secret). Throws
    /// when the list can't be read (a locked keychain), which is not the same as "nothing".
    func savedSecrets() throws -> [SavedSecret]
}

/// A saved SSH secret, named the way Tabby's keytar names it.
public enum SavedSecret: Hashable, Sendable {
    case password(host: String, port: Int, user: String)
    case passphrase(keyID: String)

    /// Parses a Keychain service / account pair; nil for items that are not TabbyMac's.
    public init?(service: String, account: String) {
        if service.hasPrefix("ssh-private-key:") {
            self = .passphrase(keyID: String(service.dropFirst("ssh-private-key:".count)))
        } else if service.hasPrefix("ssh@") {
            let rest = String(service.dropFirst(4))
            if let colon = rest.lastIndex(of: ":"), let port = Int(rest[rest.index(after: colon)...]), !rest[..<colon].isEmpty {
                self = .password(host: String(rest[..<colon]), port: port, user: account)
            } else {
                self = .password(host: rest, port: 0, user: account)
            }
        } else {
            return nil
        }
    }
}

public extension PasswordStore {
    static func service(host: String, port: Int) -> String {
        port > 0 ? "ssh@\(host):\(port)" : "ssh@\(host)"
    }

    static func keyService(_ keyID: String) -> String { "ssh-private-key:\(keyID)" }
}

/// For tests and for platforms without a keychain.
public final class InMemoryPasswordStore: PasswordStore {
    public var items: [String: String] = [:]
    public init() {}
    private func key(_ s: String, _ a: String) -> String { s + "\u{0}" + a }

    public func password(host: String, port: Int, user: String) -> String? { items[key(Self.service(host: host, port: port), user)] }
    public func hasPassword(host: String, port: Int, user: String) -> Bool { password(host: host, port: port, user: user) != nil }
    public func savePassword(_ password: String, host: String, port: Int, user: String) { items[key(Self.service(host: host, port: port), user)] = password }
    public func deletePassword(host: String, port: Int, user: String) { items[key(Self.service(host: host, port: port), user)] = nil }
    public func passphrase(keyID: String) -> String? { items[key(Self.keyService(keyID), "user")] }
    public func savePassphrase(_ passphrase: String, keyID: String) { items[key(Self.keyService(keyID), "user")] = passphrase }
    public func deletePassphrase(keyID: String) { items[key(Self.keyService(keyID), "user")] = nil }
    public func savedSecrets() throws -> [SavedSecret] {
        items.keys.compactMap { k in
            let parts = k.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return parts.count == 2 ? SavedSecret(service: parts[0], account: parts[1]) : nil
        }
    }
}

#if canImport(Security)
/// Generic-password items in the login keychain.
public final class KeychainPasswordStore: PasswordStore {
    public init() {}

    public func password(host: String, port: Int, user: String) -> String? {
        read(service: Self.service(host: host, port: port), account: user)
    }

    public func hasPassword(host: String, port: Int, user: String) -> Bool {
        var q = baseQuery(service: Self.service(host: host, port: port), account: user)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    public func savePassword(_ password: String, host: String, port: Int, user: String) {
        write(password, service: Self.service(host: host, port: port), account: user)
    }

    public func deletePassword(host: String, port: Int, user: String) {
        delete(service: Self.service(host: host, port: port), account: user)
    }

    public func passphrase(keyID: String) -> String? { read(service: Self.keyService(keyID), account: "user") }
    public func savePassphrase(_ passphrase: String, keyID: String) { write(passphrase, service: Self.keyService(keyID), account: "user") }
    public func deletePassphrase(keyID: String) { delete(service: Self.keyService(keyID), account: "user") }

    public struct KeychainError: Error, Equatable {
        public let status: OSStatus
    }

    public func savedSecrets() throws -> [SavedSecret] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else { throw KeychainError(status: status) }
        return items.compactMap { item in
            guard let service = item[kSecAttrService as String] as? String,
                  service.hasPrefix("ssh@") || service.hasPrefix("ssh-private-key:") else { return nil }
            return SavedSecret(service: service, account: item[kSecAttrAccount as String] as? String ?? "")
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(service: String, account: String) -> String? {
        var q = baseQuery(service: service, account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func write(_ value: String, service: String, account: String) {
        let data = Data(value.utf8)
        let q = baseQuery(service: service, account: account)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func delete(service: String, account: String) {
        SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
    }
}
#endif
