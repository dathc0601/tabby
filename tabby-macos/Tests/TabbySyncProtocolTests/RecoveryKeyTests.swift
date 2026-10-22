import XCTest
import TabbySyncProtocol

final class RecoveryKeyTests: XCTestCase {
    /// Expected strings come from an independent Python encoder (big-endian bit stream,
    /// 5 bits per character, Crockford alphabet).
    func testDisplayStringIsCrockfordBase32InEightGroupsOfFour() throws {
        let key = try RecoveryKey(bytes: Data(1...20))
        XCTAssertEqual(key.displayString, "0410-6105-0R3G-G28A-1C60-T3GF-208H-44RM")
        XCTAssertEqual(try RecoveryKey(bytes: Data(repeating: 0xFF, count: 20)).displayString,
                       "ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZ")
        XCTAssertEqual(try RecoveryKey(bytes: Data(count: 20)).displayString,
                       "0000-0000-0000-0000-0000-0000-0000-0000")
    }

    func testGeneratedKeysAreTwentyRandomBytes() {
        let a = RecoveryKey.generate()
        let b = RecoveryKey.generate()
        XCTAssertEqual(a.bytes.count, 20)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.displayString.count, 39)
    }

    func testParsingRoundTripsTheDisplayString() throws {
        let key = RecoveryKey.generate()
        XCTAssertEqual(try RecoveryKey(parsing: key.displayString), key)
    }

    func testParsingIsLenient() throws {
        let key = try RecoveryKey(bytes: Data(1...20))
        // Lower case, spaces instead of dashes, no separators at all.
        XCTAssertEqual(try RecoveryKey(parsing: "0410 6105 0r3g g28a 1c60 t3gf 208h 44rm"), key)
        XCTAssertEqual(try RecoveryKey(parsing: "  04106105-0R3GG28A1C60T3GF208H44RM \n"), key)
        // I and L read as 1, O reads as 0.
        XCTAssertEqual(try RecoveryKey(parsing: "O4IO-6IO5-OR3G-G28A-LC6O-T3GF-2O8H-44RM"), key)
    }

    func testParsingRejectsBadInput() {
        XCTAssertThrowsError(try RecoveryKey(parsing: "0410-6105-0R3G-G28A-1C60-T3GF-208H-44R")) // 31 chars
        XCTAssertThrowsError(try RecoveryKey(parsing: "0410-6105-0R3G-G28A-1C60-T3GF-208H-44RMM")) // 33
        XCTAssertThrowsError(try RecoveryKey(parsing: "U410-6105-0R3G-G28A-1C60-T3GF-208H-44RM")) // U is not in the alphabet
        XCTAssertThrowsError(try RecoveryKey(parsing: ""))
        XCTAssertThrowsError(try RecoveryKey(bytes: Data(count: 19)))
    }

    /// Reference values: HKDF-SHA256, empty salt, from Python's hmac module.
    func testDerivedKeysArePinned() throws {
        let key = try RecoveryKey(bytes: Data(1...20))
        XCTAssertEqual(key.authKey.hex, "49c0359cd372132f774ef9aa3c414334a3f0c6313b239018de7465dc953dd006")
        XCTAssertEqual(VaultCrypto.keyData(key.wrapKey).hex,
                       "6bbd3d1e127f89a4ec3535c23021c4c3378bb2db82c16e1528a4b089c7ac691e")
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }

    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
