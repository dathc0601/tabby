import Crypto
import XCTest
import TabbySyncProtocol

final class VaultCryptoTests: XCTestCase {
    /// Small cost so the suite stays fast; production uses `KDFParams.generate()` (n = 2^17).
    let testKDF = KDFParams(name: "scrypt", n: 1024, r: 8, p: 1, salt: Data(0..<16))

    // MARK: Key derivation

    /// RFC 7914 §12 test vector (first 32 of its 64 bytes). Pins rounds = n, blockSize = r,
    /// parallelism = p.
    func testScryptMatchesRFC7914() throws {
        let kdf = KDFParams(name: "scrypt", n: 1024, r: 8, p: 16, salt: Data("NaCl".utf8))
        let key = try VaultCrypto.masterKey(password: "password", kdf: kdf)
        XCTAssertEqual(VaultCrypto.keyData(key).hex,
                       "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b373162")
    }

    /// Reference values from Python (`hashlib.scrypt` + an `hmac` HKDF): the client of
    /// another platform must derive the same keys.
    func testPasswordKeysArePinned() throws {
        let master = try VaultCrypto.masterKey(password: "correct horse ☃", kdf: testKDF)
        XCTAssertEqual(VaultCrypto.keyData(master).hex,
                       "d29849fd08bc3324d38ab937b629f464f88a6dcdd0ad816da79c612a28955938")
        let keys = try VaultCrypto.passwordKeys(password: "correct horse ☃", kdf: testKDF)
        XCTAssertEqual(keys.authKey.hex, "071b8e31706c629f95a902d4d29bb4d1870f8557acf8320d9462186b721d39d0")
        XCTAssertEqual(VaultCrypto.keyData(keys.wrapKey).hex,
                       "d1f16e0efb8ea5555c179c431f63741520e37ad185a1a171eaad4b170d8ce7b3")
    }

    func testDefaultParamsAreScryptTwoToTheSeventeen() {
        let kdf = KDFParams.generate()
        XCTAssertEqual(kdf.name, "scrypt")
        XCTAssertEqual(kdf.n, 131_072)
        XCTAssertEqual(kdf.r, 8)
        XCTAssertEqual(kdf.p, 1)
        XCTAssertEqual(kdf.salt.count, 16)
        XCTAssertNotEqual(kdf.salt, KDFParams.generate().salt)
    }

    /// N = 2^17, r = 8 needs 128 MiB, more than BoringSSL's 32 MiB default cap.
    func testProductionCostDerives() throws {
        let kdf = KDFParams.generate()
        let a = try VaultCrypto.passwordKeys(password: "pw", kdf: kdf)
        let b = try VaultCrypto.passwordKeys(password: "pw", kdf: kdf)
        XCTAssertEqual(a.authKey, b.authKey)
        XCTAssertEqual(a.authKey.count, 32)
    }

    func testBadParamsThrowKDF() {
        let bad: [KDFParams] = [
            KDFParams(name: "argon2id", n: 1024, r: 8, p: 1, salt: Data(0..<16)),
            KDFParams(name: "scrypt", n: 1000, r: 8, p: 1, salt: Data(0..<16)), // not a power of 2
            KDFParams(name: "scrypt", n: 1024, r: 0, p: 1, salt: Data(0..<16)),
            KDFParams(name: "scrypt", n: 1024, r: 8, p: 0, salt: Data(0..<16)),
            KDFParams(name: "scrypt", n: 1024, r: 8, p: 1, salt: Data()),
            KDFParams(name: "scrypt", n: 1 << 24, r: 8, p: 1, salt: Data(0..<16)), // 16 GiB: refuse
        ]
        for kdf in bad {
            XCTAssertThrowsError(try VaultCrypto.masterKey(password: "pw", kdf: kdf), "\(kdf)") {
                XCTAssertEqual($0 as? VaultCryptoError, .kdf)
            }
        }
        XCTAssertThrowsError(try VaultCrypto.masterKey(password: "", kdf: testKDF)) {
            XCTAssertEqual($0 as? VaultCryptoError, .kdf)
        }
    }

    func testKDFParamsJSON() throws {
        let json = String(decoding: try SyncCoding.encoder.encode(testKDF), as: UTF8.self)
        XCTAssertEqual(json, #"{"n":1024,"name":"scrypt","p":1,"r":8,"salt":"AAECAwQFBgcICQoLDA0ODw=="}"#)
        XCTAssertEqual(try SyncCoding.decoder.decode(KDFParams.self, from: Data(json.utf8)), testKDF)
    }

    // MARK: Wrapping the encryption key

    func testEncryptionKeyIsRandom32Bytes() {
        let a = VaultCrypto.generateEncryptionKey()
        XCTAssertEqual(a.bitCount, 256)
        XCTAssertNotEqual(VaultCrypto.keyData(a), VaultCrypto.keyData(VaultCrypto.generateEncryptionKey()))
    }

    func testPasswordWrapRoundTrips() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        let keys = try VaultCrypto.passwordKeys(password: "pw", kdf: testKDF)
        let wrapped = try VaultCrypto.wrap(encKey, with: keys.wrapKey)
        XCTAssertEqual(wrapped.count, 12 + 32 + 16, "nonce + key + tag")
        let unwrapped = try VaultCrypto.unwrap(wrapped, with: keys.wrapKey)
        XCTAssertEqual(VaultCrypto.keyData(unwrapped), VaultCrypto.keyData(encKey))
    }

    func testWrongPasswordFailsToUnwrap() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        let right = try VaultCrypto.passwordKeys(password: "right", kdf: testKDF)
        let wrong = try VaultCrypto.passwordKeys(password: "wrong", kdf: testKDF)
        let wrapped = try VaultCrypto.wrap(encKey, with: right.wrapKey)
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: wrong.wrapKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongKey)
        }
    }

    func testTamperedWrapFails() throws {
        let keys = try VaultCrypto.passwordKeys(password: "pw", kdf: testKDF)
        var wrapped = try VaultCrypto.wrap(VaultCrypto.generateEncryptionKey(), with: keys.wrapKey)
        wrapped[20] ^= 0x01
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: keys.wrapKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongKey)
        }
        XCTAssertThrowsError(try VaultCrypto.unwrap(Data(count: 10), with: keys.wrapKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .corrupt)
        }
    }

    func testRecoveryKeyUnwrapsTheSameEncryptionKey() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        let recovery = RecoveryKey.generate()
        let wrapped = try VaultCrypto.wrap(encKey, with: recovery.wrapKey)
        // The user types the key back in, maybe in lower case.
        let typed = try RecoveryKey(parsing: recovery.displayString.lowercased())
        let unwrapped = try VaultCrypto.unwrap(wrapped, with: typed.wrapKey)
        XCTAssertEqual(VaultCrypto.keyData(unwrapped), VaultCrypto.keyData(encKey))
        XCTAssertThrowsError(try VaultCrypto.unwrap(wrapped, with: RecoveryKey.generate().wrapKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongKey)
        }
    }

    func testRecoveryAndPasswordAuthKeysDiffer() throws {
        let recovery = RecoveryKey.generate()
        XCTAssertNotEqual(recovery.authKey, VaultCrypto.keyData(recovery.wrapKey))
    }

    func testEncryptionKeyRestoresFromData() throws {
        let key = VaultCrypto.generateEncryptionKey()
        let restored = try VaultCrypto.encryptionKey(from: VaultCrypto.keyData(key))
        XCTAssertEqual(VaultCrypto.keyData(restored), VaultCrypto.keyData(key))
        XCTAssertThrowsError(try VaultCrypto.encryptionKey(from: Data(count: 16))) {
            XCTAssertEqual($0 as? VaultCryptoError, .corrupt)
        }
    }

    // MARK: Vault blob

    func testSnapshotSealRoundTrips() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        let snapshot = SyncSnapshotTests.sample()
        let blob = try VaultCrypto.sealSnapshot(snapshot, using: encKey)
        XCTAssertFalse(String(decoding: blob, as: UTF8.self).contains("prod-db"), "ciphertext, not JSON")
        XCTAssertEqual(try VaultCrypto.openSnapshot(blob, using: encKey), snapshot)
    }

    func testSnapshotWithWrongKeyOrTamperFails() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        var blob = try VaultCrypto.sealSnapshot(SyncSnapshotTests.sample(), using: encKey)
        XCTAssertThrowsError(try VaultCrypto.openSnapshot(blob, using: VaultCrypto.generateEncryptionKey())) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongKey)
        }
        blob[blob.count - 1] ^= 0x80
        XCTAssertThrowsError(try VaultCrypto.openSnapshot(blob, using: encKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongKey)
        }
    }

    /// The vault blob is bound to its purpose: a key-wrap blob sealed with the same key
    /// (no associated data) must not open as a vault.
    func testVaultBlobUsesAssociatedData() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        let json = try SyncCoding.encoder.encode(SyncSnapshotTests.sample())
        let plain = try AES.GCM.seal(json, using: encKey).combined!
        XCTAssertThrowsError(try VaultCrypto.openSnapshot(plain, using: encKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .wrongKey)
        }
        let bound = try AES.GCM.seal(json, using: encKey, authenticating: Data("tabby-vault-v1".utf8)).combined!
        XCTAssertEqual(try VaultCrypto.openSnapshot(bound, using: encKey), SyncSnapshotTests.sample())
    }

    func testOpenedGarbageIsCorrupt() throws {
        let encKey = VaultCrypto.generateEncryptionKey()
        let notJSON = try AES.GCM.seal(Data("hello".utf8), using: encKey,
                                       authenticating: Data("tabby-vault-v1".utf8)).combined!
        XCTAssertThrowsError(try VaultCrypto.openSnapshot(notJSON, using: encKey)) {
            XCTAssertEqual($0 as? VaultCryptoError, .corrupt)
        }
    }
}
