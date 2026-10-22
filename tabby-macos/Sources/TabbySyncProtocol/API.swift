import Foundation

// The HTTP API between TabbyMac and tabby-sync-server. Bodies are JSON through `SyncCoding`
// (sorted keys, base64 `Data`, millisecond ISO 8601 dates). Authenticated routes take
// `Authorization: Bearer <token>`. Errors come back as `ErrorDTO` with a matching status.

public enum APIPath {
    public static let prefix = "/v1"
    /// `GET ?email=` → `KDFResponse` (before sign-in; unknown emails get stable fake params).
    public static let accountKDF = "/v1/account/kdf"
    /// `POST RegisterRequest` → 201 `SessionResponse`; `GET` → `AccountDTO`;
    /// `DELETE DeleteAccountRequest` → 204.
    public static let account = "/v1/account"
    /// `PATCH PasswordChangeRequest` → `AccountDTO` (a recovery token becomes a full one).
    public static let accountPassword = "/v1/account/password"
    /// `PUT RecoveryRotateRequest` → `AccountDTO`.
    public static let accountRecovery = "/v1/account/recovery"
    /// `POST SessionRequest` → `SessionResponse`; `DELETE` → 204 (signs this device out).
    public static let session = "/v1/session"
    /// `POST RecoverySessionRequest` → `RecoverySessionResponse` with a limited token.
    public static let sessionRecovery = "/v1/session/recovery"
    /// `GET` → `VaultDTO` (404 when none); `PUT VaultPutRequest` with `If-Match: <revision>`
    /// (0 for the first upload) → `VaultPutResponse`, 409 + `VaultHead` when stale,
    /// 428 without `If-Match`.
    public static let vault = "/v1/vault"
    /// `GET` → `VaultHead` (404 when none).
    public static let vaultHead = "/v1/vault/head"
    /// `GET` → `[DeviceDTO]`.
    public static let devices = "/v1/devices"

    /// `DELETE` → 204: revokes that device's token (the current device signs out).
    public static func device(_ id: UUID) -> String { "\(devices)/\(id.uuidString)" }

    public static let ifMatchHeader = "If-Match"
}

public enum APILimits {
    /// Request body limit for `PUT /v1/vault` (JSON, so the ciphertext itself is about 3/4).
    public static let maxVaultBodyBytes = 25 * 1024 * 1024
    /// Request body limit for every other route.
    public static let maxBodyBytes = 64 * 1024
}

// MARK: Requests

public struct DeviceInfo: Codable, Hashable, Sendable {
    public var name: String
    public var model: String
    public var os: String

    public init(name: String, model: String, os: String) {
        self.name = name
        self.model = model
        self.os = os
    }
}

public struct RegisterRequest: Codable, Hashable, Sendable {
    public var email: String
    public var authKey: Data
    public var recoveryAuthKey: Data
    public var kdf: KDFParams
    public var wrappedByPassword: Data
    public var wrappedByRecovery: Data
    public var device: DeviceInfo

    public init(email: String, authKey: Data, recoveryAuthKey: Data, kdf: KDFParams,
                wrappedByPassword: Data, wrappedByRecovery: Data, device: DeviceInfo) {
        self.email = email
        self.authKey = authKey
        self.recoveryAuthKey = recoveryAuthKey
        self.kdf = kdf
        self.wrappedByPassword = wrappedByPassword
        self.wrappedByRecovery = wrappedByRecovery
        self.device = device
    }
}

public struct SessionRequest: Codable, Hashable, Sendable {
    public var email: String
    public var authKey: Data
    public var device: DeviceInfo

    public init(email: String, authKey: Data, device: DeviceInfo) {
        self.email = email
        self.authKey = authKey
        self.device = device
    }
}

public struct RecoverySessionRequest: Codable, Hashable, Sendable {
    public var email: String
    public var recoveryAuthKey: Data
    public var device: DeviceInfo

    public init(email: String, recoveryAuthKey: Data, device: DeviceInfo) {
        self.email = email
        self.recoveryAuthKey = recoveryAuthKey
        self.device = device
    }
}

/// Exactly one proof: `authKey` (the current password) or `recoveryAuthKey` (the recovery
/// key; also accepted from a recovery-scoped token, which this request upgrades).
public struct PasswordChangeRequest: Codable, Hashable, Sendable {
    public var authKey: Data?
    public var recoveryAuthKey: Data?
    public var newAuthKey: Data
    public var newKdf: KDFParams
    public var newWrappedByPassword: Data

    public init(authKey: Data? = nil, recoveryAuthKey: Data? = nil, newAuthKey: Data, newKdf: KDFParams,
                newWrappedByPassword: Data) {
        self.authKey = authKey
        self.recoveryAuthKey = recoveryAuthKey
        self.newAuthKey = newAuthKey
        self.newKdf = newKdf
        self.newWrappedByPassword = newWrappedByPassword
    }
}

/// Replaces the recovery key ("Regenerate…"); proven with the password's `authKey`.
public struct RecoveryRotateRequest: Codable, Hashable, Sendable {
    public var authKey: Data
    public var newRecoveryAuthKey: Data
    public var newWrappedByRecovery: Data

    public init(authKey: Data, newRecoveryAuthKey: Data, newWrappedByRecovery: Data) {
        self.authKey = authKey
        self.newRecoveryAuthKey = newRecoveryAuthKey
        self.newWrappedByRecovery = newWrappedByRecovery
    }
}

public struct DeleteAccountRequest: Codable, Hashable, Sendable {
    public var authKey: Data

    public init(authKey: Data) {
        self.authKey = authKey
    }
}

public struct VaultPutRequest: Codable, Hashable, Sendable {
    public var ciphertext: Data

    public init(ciphertext: Data) {
        self.ciphertext = ciphertext
    }
}

// MARK: Responses

public struct KDFResponse: Codable, Hashable, Sendable {
    public var kdf: KDFParams

    public init(kdf: KDFParams) {
        self.kdf = kdf
    }
}

public struct AccountDTO: Codable, Hashable, Sendable {
    public var id: UUID
    public var email: String
    public var createdAt: Date
    public var kdf: KDFParams
    public var wrappedByPassword: Data
    public var recoveryUpdatedAt: Date

    public init(id: UUID, email: String, createdAt: Date, kdf: KDFParams, wrappedByPassword: Data,
                recoveryUpdatedAt: Date) {
        self.id = id
        self.email = email
        self.createdAt = createdAt
        self.kdf = kdf
        self.wrappedByPassword = wrappedByPassword
        self.recoveryUpdatedAt = recoveryUpdatedAt
    }
}

public struct DeviceDTO: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var model: String
    public var os: String
    public var createdAt: Date
    public var lastSeenAt: Date
    /// The device whose token made the request.
    public var isCurrent: Bool

    public init(id: UUID, name: String, model: String, os: String, createdAt: Date, lastSeenAt: Date,
                isCurrent: Bool) {
        self.id = id
        self.name = name
        self.model = model
        self.os = os
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isCurrent = isCurrent
    }
}

public struct SessionResponse: Codable, Hashable, Sendable {
    public var token: String
    public var account: AccountDTO
    public var device: DeviceDTO

    public init(token: String, account: AccountDTO, device: DeviceDTO) {
        self.token = token
        self.account = account
        self.device = device
    }
}

/// The token is limited to `GET /account`, `GET /vault` and `PATCH /account/password`
/// until the password is changed. The client unwraps `encKey` with the recovery key.
public struct RecoverySessionResponse: Codable, Hashable, Sendable {
    public var token: String
    public var account: AccountDTO
    public var device: DeviceDTO
    public var wrappedByRecovery: Data

    public init(token: String, account: AccountDTO, device: DeviceDTO, wrappedByRecovery: Data) {
        self.token = token
        self.account = account
        self.device = device
        self.wrappedByRecovery = wrappedByRecovery
    }
}

public struct VaultHead: Codable, Hashable, Sendable {
    public var revision: Int
    public var modifiedAt: Date
    /// The server id of the device that uploaded this revision.
    public var deviceId: UUID

    public init(revision: Int, modifiedAt: Date, deviceId: UUID) {
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceId = deviceId
    }
}

public struct VaultDTO: Codable, Hashable, Sendable {
    public var revision: Int
    public var modifiedAt: Date
    public var deviceId: UUID
    /// `VaultCrypto.sealSnapshot` output.
    public var ciphertext: Data

    public init(revision: Int, modifiedAt: Date, deviceId: UUID, ciphertext: Data) {
        self.revision = revision
        self.modifiedAt = modifiedAt
        self.deviceId = deviceId
        self.ciphertext = ciphertext
    }

    public var head: VaultHead { VaultHead(revision: revision, modifiedAt: modifiedAt, deviceId: deviceId) }
}

public struct VaultPutResponse: Codable, Hashable, Sendable {
    public var revision: Int
    public var modifiedAt: Date

    public init(revision: Int, modifiedAt: Date) {
        self.revision = revision
        self.modifiedAt = modifiedAt
    }
}

public struct ErrorDTO: Codable, Hashable, Sendable {
    /// A machine-readable code from `ErrorDTO.Code`.
    public var error: String
    /// A human-readable explanation (English).
    public var message: String

    public init(error: String, message: String) {
        self.error = error
        self.message = message
    }

    public enum Code {
        public static let badRequest = "bad_request"                 // 400
        public static let invalidEmail = "invalid_email"             // 400
        public static let unauthorized = "unauthorized"              // 401: no or revoked token
        public static let invalidCredentials = "invalid_credentials" // 401: wrong email or key
        public static let forbidden = "forbidden"                    // 403: recovery-scoped token
        public static let notFound = "not_found"                     // 404
        public static let emailTaken = "email_taken"                 // 409
        public static let conflict = "conflict"                      // 409: stale If-Match
        public static let payloadTooLarge = "payload_too_large"      // 413
        public static let preconditionRequired = "precondition_required" // 428: no If-Match
        public static let rateLimited = "rate_limited"               // 429
        public static let internalError = "internal_error"           // 500
    }
}
