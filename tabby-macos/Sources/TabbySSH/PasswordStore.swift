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
    func savePassword(_ password: String, host: String, port: Int, user: String)
    func deletePassword(host: String, port: Int, user: String)
    func passphrase(keyID: String) -> String?
    func savePassphrase(_ passphrase: String, keyID: String)
    func deletePassphrase(keyID: String)
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
    public func savePassword(_ password: String, host: String, port: Int, user: String) { items[key(Self.service(host: host, port: port), user)] = password }
    public func deletePassword(host: String, port: Int, user: String) { items[key(Self.service(host: host, port: port), user)] = nil }
    public func passphrase(keyID: String) -> String? { items[key(Self.keyService(keyID), "user")] }
    public func savePassphrase(_ passphrase: String, keyID: String) { items[key(Self.keyService(keyID), "user")] = passphrase }
    public func deletePassphrase(keyID: String) { items[key(Self.keyService(keyID), "user")] = nil }
}

#if canImport(Security)
/// Generic-password items in the login keychain.
public final class KeychainPasswordStore: PasswordStore {
    public init() {}

    public func password(host: String, port: Int, user: String) -> String? {
        read(service: Self.service(host: host, port: port), account: user)
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
