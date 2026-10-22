import _CryptoExtras
import Crypto
import Foundation

public enum VaultCryptoError: Error, Equatable, Sendable {
    /// Authentication failed: wrong password / recovery key / encryption key, or tampered data.
    case wrongKey
    /// The data is not shaped like what was expected (too short, not a snapshot).
    case corrupt
    /// The key-derivation parameters are unsupported or derivation failed.
    case kdf
}

/// Password key-derivation parameters, stored per account and returned before sign-in.
public struct KDFParams: Codable, Hashable, Sendable {
    public static let scryptName = "scrypt"
    public static let defaultN = 131_072 // 2^17: 128 MiB, ~0.3-0.5 s on a recent Mac
    public static let defaultR = 8
    public static let defaultP = 1
    public static let saltByteCount = 16

    public var name: String
    public var n: Int
    public var r: Int
    public var p: Int
    public var salt: Data

    public init(name: String = KDFParams.scryptName, n: Int, r: Int, p: Int, salt: Data) {
        self.name = name
        self.n = n
        self.r = r
        self.p = p
        self.salt = salt
    }

    /// Fresh parameters with a random salt, as made at sign-up and on a password change.
    public static func generate(n: Int = defaultN, r: Int = defaultR, p: Int = defaultP) -> KDFParams {
        KDFParams(n: n, r: r, p: p, salt: VaultCrypto.randomBytes(saltByteCount))
    }

    /// Bytes scrypt allocates (BoringSSL's accounting: `128 · r · (N + p + 1)`).
    var requiredMemory: Int { 128 * r * (n + p + 1) }

    /// Refuses unknown algorithms and costs a hostile server could use to exhaust the client.
    var isSupported: Bool {
        name == Self.scryptName
            && n > 1 && n <= 1 << 20 && n & (n - 1) == 0
            && (1...32).contains(r) && (1...16).contains(p)
            && !salt.isEmpty
            && requiredMemory <= VaultCrypto.maxScryptMemory
    }
}

/// The keys a password yields: `authKey` signs in (the server keeps a salted hash),
/// `wrapKey` unwraps the encryption key and never leaves the device.
///
/// `@unchecked`: swift-crypto 3.x does not mark `SymmetricKey` `Sendable` on Linux; it is
/// an immutable value.
public struct PasswordKeys: @unchecked Sendable {
    public let authKey: Data
    public let wrapKey: SymmetricKey
}

/// The account's key hierarchy:
///
///     masterKey = scrypt(password, kdf.salt, N, r, p, 32 bytes)
///     authKey   = HKDF-SHA256(masterKey, info "tabby-auth", 32)          -> server (hashed)
///     wrapKey   = HKDF-SHA256(masterKey, info "tabby-wrap", 32)
///     encKey    = 32 random bytes, made at sign-up
///     wrappedByPassword = AES-GCM(wrapKey, encKey)                       -> server
///     wrappedByRecovery = AES-GCM(RecoveryKey.wrapKey, encKey)           -> server
///     vault     = AES-GCM(encKey, snapshot JSON, aad "tabby-vault-v1")   -> server
///
/// All AES-GCM values are `nonce ‖ ciphertext ‖ tag` (CryptoKit's `combined`). The server
/// never sees the password, the recovery key or `encKey`. A password change re-wraps
/// `encKey`; the vault is not re-encrypted.
public enum VaultCrypto {
    static let authInfo = Data("tabby-auth".utf8)
    static let wrapInfo = Data("tabby-wrap".utf8)
    static let recoveryWrapInfo = Data("tabby-recovery-wrap".utf8)
    static let recoveryAuthInfo = Data("tabby-recovery-auth".utf8)
    public static let vaultAssociatedData = Data("tabby-vault-v1".utf8)
    static let maxScryptMemory = 1 << 30

    // MARK: Password

    public static func masterKey(password: String, kdf: KDFParams) throws -> SymmetricKey {
        let passwordBytes = Data(password.utf8)
        guard kdf.isSupported, !passwordBytes.isEmpty else { throw VaultCryptoError.kdf }
        do {
            return try KDF.Scrypt.deriveKey(
                from: passwordBytes, salt: kdf.salt, outputByteCount: 32,
                rounds: kdf.n, blockSize: kdf.r, parallelism: kdf.p,
                // BoringSSL's default cap is 32 MiB; N = 2^17, r = 8 needs 128 MiB.
                maxMemory: kdf.requiredMemory + 64 * 1024)
        } catch {
            throw VaultCryptoError.kdf
        }
    }

    public static func passwordKeys(password: String, kdf: KDFParams) throws -> PasswordKeys {
        passwordKeys(masterKey: try masterKey(password: password, kdf: kdf))
    }

    public static func passwordKeys(masterKey: SymmetricKey) -> PasswordKeys {
        PasswordKeys(authKey: keyData(hkdf(masterKey, info: authInfo)), wrapKey: hkdf(masterKey, info: wrapInfo))
    }

    // MARK: Encryption key

    public static func generateEncryptionKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Restores an encryption key saved with `keyData` (for example in the Keychain).
    public static func encryptionKey(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw VaultCryptoError.corrupt }
        return SymmetricKey(data: data)
    }

    public static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    /// `wrappedByPassword` / `wrappedByRecovery`.
    public static func wrap(_ encryptionKey: SymmetricKey, with wrapKey: SymmetricKey) throws -> Data {
        try seal(keyData(encryptionKey), using: wrapKey, authenticating: Data())
    }

    public static func unwrap(_ wrapped: Data, with wrapKey: SymmetricKey) throws -> SymmetricKey {
        try encryptionKey(from: open(wrapped, using: wrapKey, authenticating: Data()))
    }

    // MARK: Vault blob

    public static func sealSnapshot(_ snapshot: SyncSnapshot, using encryptionKey: SymmetricKey) throws -> Data {
        try seal(SyncCoding.encoder.encode(snapshot), using: encryptionKey, authenticating: vaultAssociatedData)
    }

    public static func openSnapshot(_ blob: Data, using encryptionKey: SymmetricKey) throws -> SyncSnapshot {
        let json = try open(blob, using: encryptionKey, authenticating: vaultAssociatedData)
        do {
            return try SyncCoding.decoder.decode(SyncSnapshot.self, from: json)
        } catch {
            throw VaultCryptoError.corrupt
        }
    }

    // MARK: Primitives

    public static func randomBytes(_ count: Int) -> Data {
        keyData(SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)))
    }

    static func hkdf(_ inputKeyMaterial: SymmetricKey, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: inputKeyMaterial, info: info, outputByteCount: 32)
    }

    static func seal(_ plaintext: Data, using key: SymmetricKey, authenticating aad: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined else {
            throw VaultCryptoError.corrupt
        }
        return combined
    }

    static func open(_ combined: Data, using key: SymmetricKey, authenticating aad: Data) throws -> Data {
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw VaultCryptoError.corrupt
        }
        do {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw VaultCryptoError.wrongKey
        }
    }
}
