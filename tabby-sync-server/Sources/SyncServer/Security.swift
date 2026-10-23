import Crypto
import Foundation
import TabbySyncProtocol

/// Hashing and comparison of the secrets the server stores.
enum Security {
    static let authKeyByteCount = 32
    static let saltByteCount = 16

    /// `SHA256(key ‖ salt)`: what the server stores for an auth key or a recovery auth key.
    static func hashKey(_ key: Data, salt: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: key)
        hasher.update(data: salt)
        return Data(hasher.finalize())
    }

    /// Compares `key` with a stored hash in constant time.
    static func verifyKey(_ key: Data, salt: Data, hash: Data) -> Bool {
        constantTimeEquals(hashKey(key, salt: salt), hash)
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// A bearer token (32 random bytes, base64url without padding) and the hash to store.
    static func newToken() -> (token: String, hash: Data) {
        let token = VaultCrypto.randomBytes(32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return (token, tokenHash(token))
    }

    static func tokenHash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    /// Default KDF parameters with a salt that is stable per email and unguessable without
    /// the server secret, answered for emails without an account.
    static func fakeKDF(email: String, secret: Data) -> KDFParams {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(email.utf8), using: SymmetricKey(data: secret))
        return KDFParams(n: KDFParams.defaultN, r: KDFParams.defaultR, p: KDFParams.defaultP,
                         salt: Data(mac).prefix(KDFParams.saltByteCount))
    }

    /// Trims and lowercases; nil unless it looks like `local@domain.tld`.
    static func normalizeEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty, email.count <= 254, !email.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64 else { return nil }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), !domain.contains("..") else {
            return nil
        }
        return email
    }

    /// The current time at the millisecond precision dates have on the wire.
    static func now() -> Date {
        Date(timeIntervalSince1970: Double(SyncCoding.milliseconds(Date())) / 1000)
    }
}
