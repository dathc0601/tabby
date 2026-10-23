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

/// Sync uploads the SSH secrets TabbyMac saved: passwords (`ssh@host:port` / user) and key
/// passphrases (`ssh-private-key:<id>`). Listing reads names, never secrets.
final class PasswordStoreListingTests: XCTestCase {
    func testListsSavedPasswordsAndPassphrases() throws {
        let store = InMemoryPasswordStore()
        store.savePassword("a", host: "example.com", port: 22, user: "deploy")
        store.savePassword("b", host: "db.internal", port: 2222, user: "postgres")
        store.savePassphrase("c", keyID: "abc123")
        store.items["unrelated\u{0}someone"] = "x"
        XCTAssertEqual(Set(try store.savedSecrets()), [
            .password(host: "example.com", port: 22, user: "deploy"),
            .password(host: "db.internal", port: 2222, user: "postgres"),
            .passphrase(keyID: "abc123"),
        ])
    }

    func testServiceNamesParseBack() {
        XCTAssertEqual(SavedSecret(service: "ssh@example.com:22", account: "me"), .password(host: "example.com", port: 22, user: "me"))
        XCTAssertEqual(SavedSecret(service: "ssh@example.com", account: "me"), .password(host: "example.com", port: 0, user: "me"))
        XCTAssertEqual(SavedSecret(service: "ssh@[::1]:22", account: "me"), .password(host: "[::1]", port: 22, user: "me"))
        XCTAssertEqual(SavedSecret(service: "ssh-private-key:ff00", account: "user"), .passphrase(keyID: "ff00"))
        XCTAssertNil(SavedSecret(service: "github.com", account: "me"))
    }
}
