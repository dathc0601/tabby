import Crypto
import Foundation
import TabbySyncProtocol

/// What this Mac keeps while signed in: the bearer token and the vault's encryption key
/// (in the Keychain when "Keep me signed in" is on, in memory otherwise).
public struct AccountSession: Codable, Equatable, Sendable {
    public var email: String
    public var accountID: UUID
    public var deviceID: UUID
    public var token: String
    /// The 32-byte vault key (`encKey`).
    public var encryptionKey: Data
    /// Known on the Mac that created or rotated it, and on others once the vault is read.
    public var recoveryKey: String?

    public init(email: String, accountID: UUID, deviceID: UUID, token: String, encryptionKey: Data, recoveryKey: String? = nil) {
        self.email = email
        self.accountID = accountID
        self.deviceID = deviceID
        self.token = token
        self.encryptionKey = encryptionKey
        self.recoveryKey = recoveryKey
    }
}

/// Account operations on the client side of `VaultCrypto`'s key hierarchy. They run scrypt,
/// so call them off the main actor (they are nonisolated async functions).
public enum AccountFlows {
    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Creates the account; returns the session and the recovery key to show once.
    public static func register(client: SyncClient, email rawEmail: String, password: String, device: DeviceInfo,
                                kdf: KDFParams = .generate()) async throws -> (AccountSession, RecoveryKey) {
        let email = normalize(rawEmail)
        let keys = try VaultCrypto.passwordKeys(password: password, kdf: kdf)
        let encryptionKey = VaultCrypto.generateEncryptionKey()
        let recovery = RecoveryKey.generate()
        let response = try await client.register(RegisterRequest(
            email: email, authKey: keys.authKey, recoveryAuthKey: recovery.authKey, kdf: kdf,
            wrappedByPassword: try VaultCrypto.wrap(encryptionKey, with: keys.wrapKey),
            wrappedByRecovery: try VaultCrypto.wrap(encryptionKey, with: recovery.wrapKey),
            device: device))
        client.token = response.token
        let session = AccountSession(email: response.account.email, accountID: response.account.id, deviceID: response.device.id,
                                     token: response.token, encryptionKey: VaultCrypto.keyData(encryptionKey),
                                     recoveryKey: recovery.displayString)
        return (session, recovery)
    }

    public static func signIn(client: SyncClient, email rawEmail: String, password: String, device: DeviceInfo) async throws -> AccountSession {
        let email = normalize(rawEmail)
        let kdf = try await client.kdf(email: email)
        let keys = try VaultCrypto.passwordKeys(password: password, kdf: kdf)
        let response = try await client.signIn(SessionRequest(email: email, authKey: keys.authKey, device: device))
        client.token = response.token
        let encryptionKey = try VaultCrypto.unwrap(response.account.wrappedByPassword, with: keys.wrapKey)
        return AccountSession(email: response.account.email, accountID: response.account.id, deviceID: response.device.id,
                              token: response.token, encryptionKey: VaultCrypto.keyData(encryptionKey))
    }

    /// "Forgot password?": signs in with the recovery key and sets a new password.
    public static func recover(client: SyncClient, email rawEmail: String, recoveryKey: RecoveryKey, newPassword: String,
                               device: DeviceInfo, kdf: KDFParams = .generate()) async throws -> AccountSession {
        let email = normalize(rawEmail)
        let response = try await client.recoverySignIn(RecoverySessionRequest(email: email, recoveryAuthKey: recoveryKey.authKey, device: device))
        client.token = response.token
        let encryptionKey = try VaultCrypto.unwrap(response.wrappedByRecovery, with: recoveryKey.wrapKey)
        let keys = try VaultCrypto.passwordKeys(password: newPassword, kdf: kdf)
        try await client.changePassword(PasswordChangeRequest(
            recoveryAuthKey: recoveryKey.authKey, newAuthKey: keys.authKey, newKdf: kdf,
            newWrappedByPassword: try VaultCrypto.wrap(encryptionKey, with: keys.wrapKey)))
        return AccountSession(email: response.account.email, accountID: response.account.id, deviceID: response.device.id,
                              token: response.token, encryptionKey: VaultCrypto.keyData(encryptionKey),
                              recoveryKey: recoveryKey.displayString)
    }

    /// Re-wraps the encryption key under a new password; the vault is not re-encrypted.
    public static func changePassword(client: SyncClient, email rawEmail: String, oldPassword: String, newPassword: String,
                                      kdf: KDFParams = .generate()) async throws {
        let account = try await client.account()
        let old = try VaultCrypto.passwordKeys(password: oldPassword, kdf: account.kdf)
        let encryptionKey = try VaultCrypto.unwrap(account.wrappedByPassword, with: old.wrapKey)
        let new = try VaultCrypto.passwordKeys(password: newPassword, kdf: kdf)
        try await client.changePassword(PasswordChangeRequest(
            authKey: old.authKey, newAuthKey: new.authKey, newKdf: kdf,
            newWrappedByPassword: try VaultCrypto.wrap(encryptionKey, with: new.wrapKey)))
    }

    /// Makes a new recovery key; the old one stops working.
    public static func rotateRecoveryKey(client: SyncClient, session: AccountSession, password: String) async throws -> RecoveryKey {
        let account = try await client.account()
        let keys = try VaultCrypto.passwordKeys(password: password, kdf: account.kdf)
        let encryptionKey = try VaultCrypto.encryptionKey(from: session.encryptionKey)
        let recovery = RecoveryKey.generate()
        try await client.rotateRecovery(RecoveryRotateRequest(
            authKey: keys.authKey, newRecoveryAuthKey: recovery.authKey,
            newWrappedByRecovery: try VaultCrypto.wrap(encryptionKey, with: recovery.wrapKey)))
        return recovery
    }

    /// Checks the password against the account (the Security section asks before showing the
    /// recovery key).
    public static func verifyPassword(client: SyncClient, password: String) async throws -> Bool {
        let account = try await client.account()
        let keys = try VaultCrypto.passwordKeys(password: password, kdf: account.kdf)
        return (try? VaultCrypto.unwrap(account.wrappedByPassword, with: keys.wrapKey)) != nil
    }

    public static func deleteAccount(client: SyncClient, password: String) async throws {
        let account = try await client.account()
        let keys = try VaultCrypto.passwordKeys(password: password, kdf: account.kdf)
        try await client.deleteAccount(DeleteAccountRequest(authKey: keys.authKey))
    }
}
