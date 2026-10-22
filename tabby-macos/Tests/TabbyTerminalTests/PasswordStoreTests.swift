import XCTest
@testable import TabbySSH

/// The profile editor shows "Saved in Keychain" without reading the secret: on ad-hoc signed
/// builds reading an item can raise a Keychain access prompt, checking for one does not.
final class PasswordStoreTests: XCTestCase {
    func testHasPasswordWithoutReadingIt() {
        let store = InMemoryPasswordStore()
        XCTAssertFalse(store.hasPassword(host: "example.com", port: 22, user: "deploy"))
        store.savePassword("s3cret", host: "example.com", port: 22, user: "deploy")
        XCTAssertTrue(store.hasPassword(host: "example.com", port: 22, user: "deploy"))
        XCTAssertFalse(store.hasPassword(host: "example.com", port: 2222, user: "deploy"))
        store.deletePassword(host: "example.com", port: 22, user: "deploy")
        XCTAssertFalse(store.hasPassword(host: "example.com", port: 22, user: "deploy"))
    }
}
