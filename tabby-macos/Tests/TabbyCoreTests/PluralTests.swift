import XCTest
@testable import TabbyCore

/// Found in the M7 walk: "1 passwords · 1 keys", "1 profiles, 1 passwords, 1 keys".
final class PluralTests: XCTestCase {
    func testOneIsSingularEverythingElsePlural() {
        XCTAssertEqual(Plural.count(1, "password"), "1 password")
        XCTAssertEqual(Plural.count(2, "password"), "2 passwords")
        XCTAssertEqual(Plural.count(0, "key"), "0 keys")
        XCTAssertEqual(Plural.count(1, "profile"), "1 profile")
    }
}
