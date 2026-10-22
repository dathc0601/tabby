import FluentKit
import Foundation
import TabbySyncProtocol

/// An account. The server keeps only salted hashes of the auth keys and the encryption key
/// wrapped by the password and by the recovery key; it never sees either secret.
final class Account: Model, @unchecked Sendable {
    static let schema = "accounts"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    /// Salt for `authKeyHash` and `recoveryAuthKeyHash`.
    @Field(key: "key_salt") var keySalt: Data
    @Field(key: "auth_key_hash") var authKeyHash: Data
    @Field(key: "recovery_auth_key_hash") var recoveryAuthKeyHash: Data
    @Field(key: "kdf_name") var kdfName: String
    @Field(key: "kdf_n") var kdfN: Int
    @Field(key: "kdf_r") var kdfR: Int
    @Field(key: "kdf_p") var kdfP: Int
    @Field(key: "kdf_salt") var kdfSalt: Data
    @Field(key: "wrapped_by_password") var wrappedByPassword: Data
    @Field(key: "wrapped_by_recovery") var wrappedByRecovery: Data
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "recovery_updated_at") var recoveryUpdatedAt: Date

    init() {}

    var kdf: KDFParams {
        get { KDFParams(name: kdfName, n: kdfN, r: kdfR, p: kdfP, salt: kdfSalt) }
        set {
            kdfName = newValue.name
            kdfN = newValue.n
            kdfR = newValue.r
            kdfP = newValue.p
            kdfSalt = newValue.salt
        }
    }

    var dto: AccountDTO {
        AccountDTO(id: id!, email: email, createdAt: createdAt, kdf: kdf, wrappedByPassword: wrappedByPassword,
                   recoveryUpdatedAt: recoveryUpdatedAt)
    }
}

/// A signed-in device. Its bearer token is stored as a SHA-256 hash; deleting the row
/// revokes the token.
final class Device: Model, @unchecked Sendable {
    static let schema = "devices"

    enum Scope: String {
        case full
        /// Signed in with the recovery key: may read the account and the vault and set a
        /// new password, which upgrades it to `full`.
        case recovery
    }

    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountID: UUID
    @Field(key: "name") var name: String
    @Field(key: "model") var model: String
    @Field(key: "os") var os: String
    @Field(key: "token_hash") var tokenHash: Data
    @Field(key: "scope") var scope: String
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "last_seen_at") var lastSeenAt: Date

    init() {}

    func dto(currentDeviceID: UUID?) -> DeviceDTO {
        DeviceDTO(id: id!, name: name, model: model, os: os, createdAt: createdAt, lastSeenAt: lastSeenAt,
                  isCurrent: id == currentDeviceID)
    }
}

/// The account's encrypted snapshot (one per account) with its revision.
final class Vault: Model, @unchecked Sendable {
    static let schema = "vaults"

    @ID(key: .id) var id: UUID?
    @Field(key: "account_id") var accountID: UUID
    @Field(key: "revision") var revision: Int
    @Field(key: "modified_at") var modifiedAt: Date
    /// The device that uploaded this revision.
    @Field(key: "device_id") var deviceID: UUID
    @Field(key: "ciphertext") var ciphertext: Data

    init() {}

    var head: VaultHead { VaultHead(revision: revision, modifiedAt: modifiedAt, deviceId: deviceID) }
    var dto: VaultDTO { VaultDTO(revision: revision, modifiedAt: modifiedAt, deviceId: deviceID, ciphertext: ciphertext) }
}

struct CreateAccounts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Account.schema)
            .id()
            .field("email", .string, .required)
            .field("key_salt", .data, .required)
            .field("auth_key_hash", .data, .required)
            .field("recovery_auth_key_hash", .data, .required)
            .field("kdf_name", .string, .required)
            .field("kdf_n", .int, .required)
            .field("kdf_r", .int, .required)
            .field("kdf_p", .int, .required)
            .field("kdf_salt", .data, .required)
            .field("wrapped_by_password", .data, .required)
            .field("wrapped_by_recovery", .data, .required)
            .field("created_at", .datetime, .required)
            .field("recovery_updated_at", .datetime, .required)
            .unique(on: "email")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Account.schema).delete()
    }
}

struct CreateDevices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Device.schema)
            .id()
            .field("account_id", .uuid, .required, .references(Account.schema, "id", onDelete: .cascade))
            .field("name", .string, .required)
            .field("model", .string, .required)
            .field("os", .string, .required)
            .field("token_hash", .data, .required)
            .field("scope", .string, .required)
            .field("created_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Device.schema).delete()
    }
}

struct CreateVaults: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Vault.schema)
            .id()
            .field("account_id", .uuid, .required, .references(Account.schema, "id", onDelete: .cascade))
            .field("revision", .int, .required)
            .field("modified_at", .datetime, .required)
            .field("device_id", .uuid, .required)
            .field("ciphertext", .data, .required)
            .unique(on: "account_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Vault.schema).delete()
    }
}
