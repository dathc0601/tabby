import Crypto
import Foundation

public enum RecoveryKeyError: Error, Equatable, Sendable {
    /// Not 32 characters (or 20 bytes) once spaces and dashes are removed.
    case wrongLength
    /// A character outside Crockford's base32 alphabet.
    case invalidCharacter(Character)
}

/// The account's recovery key: 20 random bytes, shown as 32 Crockford base32 characters
/// in 8 groups of 4 (`K7QF-9MXA-…`). It wraps the vault's encryption key a second time
/// and signs in when the password is lost.
public struct RecoveryKey: Hashable, Sendable {
    public static let byteCount = 20
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)

    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw RecoveryKeyError.wrongLength }
        self.bytes = bytes
    }

    public static func generate() -> RecoveryKey {
        try! RecoveryKey(bytes: VaultCrypto.randomBytes(byteCount))
    }

    /// Reads a key the user typed: case-insensitive, spaces and dashes ignored, I and L read
    /// as 1 and O as 0.
    public init(parsing string: String) throws {
        var values: [UInt8] = []
        for character in string.uppercased() {
            if character == "-" || character.isWhitespace { continue }
            let normalized: Character
            switch character {
            case "I", "L": normalized = "1"
            case "O": normalized = "0"
            default: normalized = character
            }
            guard let ascii = normalized.asciiValue, let value = Self.alphabet.firstIndex(of: ascii) else {
                throw RecoveryKeyError.invalidCharacter(character)
            }
            values.append(UInt8(value))
        }
        guard values.count == 32 else { throw RecoveryKeyError.wrongLength }

        var bytes = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for value in values {
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits)))
            }
        }
        try self.init(bytes: bytes)
    }

    /// `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX`
    public var displayString: String {
        var characters: [Character] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                characters.append(Character(Unicode.Scalar(Self.alphabet[Int((buffer >> UInt32(bits)) & 31)])))
            }
        }
        return stride(from: 0, to: characters.count, by: 4)
            .map { String(characters[$0..<min($0 + 4, characters.count)]) }
            .joined(separator: "-")
    }

    /// Wraps the encryption key (`wrappedByRecovery`). Never leaves the device.
    public var wrapKey: SymmetricKey {
        VaultCrypto.hkdf(SymmetricKey(data: bytes), info: VaultCrypto.recoveryWrapInfo)
    }

    /// Proves knowledge of the key to the server (`recoveryAuthKey`); stored there hashed.
    public var authKey: Data {
        VaultCrypto.keyData(VaultCrypto.hkdf(SymmetricKey(data: bytes), info: VaultCrypto.recoveryAuthInfo))
    }
}
