import Foundation
#if canImport(Security)
import Security
#endif
import TabbySSH

/// Where the signed-in session is kept.
public protocol SessionStore: AnyObject {
    func load() -> AccountSession?
    func save(_ session: AccountSession)
    func clear()
}

/// "Keep me signed in" off: the session ends with the app.
public final class MemorySessionStore: SessionStore {
    private var session: AccountSession?
    public init(_ session: AccountSession? = nil) { self.session = session }
    public func load() -> AccountSession? { session }
    public func save(_ session: AccountSession) { self.session = session }
    public func clear() { session = nil }
}

#if canImport(Security)
/// The token and vault key as one generic-password item in the login keychain.
public final class KeychainSessionStore: SessionStore {
    let service: String

    public init(service: String = "TabbyMac account") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    public func load() -> AccountSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AccountSession.self, from: data)
    }

    public func save(_ session: AccountSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        if SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = service
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
#endif

/// Passes everything to another store and reports saves and deletions, so a password
/// remembered while connecting syncs to the other Macs.
public final class NotifyingPasswordStore: PasswordStore {
    public let base: PasswordStore
    public var onChange: (() -> Void)?

    public init(_ base: PasswordStore) {
        self.base = base
    }

    private func changed() {
        if Thread.isMainThread { onChange?() } else { DispatchQueue.main.async { self.onChange?() } }
    }

    public func password(host: String, port: Int, user: String) -> String? { base.password(host: host, port: port, user: user) }
    public func hasPassword(host: String, port: Int, user: String) -> Bool { base.hasPassword(host: host, port: port, user: user) }
    public func savePassword(_ password: String, host: String, port: Int, user: String) {
        base.savePassword(password, host: host, port: port, user: user)
        changed()
    }
    public func deletePassword(host: String, port: Int, user: String) {
        base.deletePassword(host: host, port: port, user: user)
        changed()
    }
    public func passphrase(keyID: String) -> String? { base.passphrase(keyID: keyID) }
    public func savePassphrase(_ passphrase: String, keyID: String) {
        base.savePassphrase(passphrase, keyID: keyID)
        changed()
    }
    public func deletePassphrase(keyID: String) {
        base.deletePassphrase(keyID: keyID)
        changed()
    }
    public func savedSecrets() -> [SavedSecret] { base.savedSecrets() }
}
