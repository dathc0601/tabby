import XCTest
@testable import TabbyCore

/// Found in the M7 walk: "1 passwords · 1 keys", "1 profiles, 1 passwords, 1 keys".
final class PluralTests: XCTestCase {
    func testOneIsSingularEverythingElsePlural() {
        XCTAssertEqual(Plural.count(1, one: "1 password", other: "{n} passwords"), "1 password")
        XCTAssertEqual(Plural.count(2, one: "1 password", other: "{n} passwords"), "2 passwords")
        XCTAssertEqual(Plural.count(0, one: "1 key", other: "{n} keys"), "0 keys")
        XCTAssertEqual(Plural.count(1_000, one: "1 profile", other: "{n} profiles"), "1000 profiles")
    }
}
