import XCTest
import TabbySyncProtocol
@testable import TabbyAccount

/// Sign-up, sign-in, recovery and password changes against the fake server: the server only
/// ever sees derived keys and wrapped keys, and every path ends with the same encryption key.
final class AccountFlowTests: XCTestCase {
    var server: FakeSyncServer!
    var client: SyncClient!

    override func setUpWithError() throws {
        server = FakeSyncServer()
        client = try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server)
    }

    func newClient() throws -> SyncClient {
        try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server)
    }

    func testRegisterThenSignInOnAnotherMacUnwrapsTheSameKey() async throws {
        let (session, recovery) = try await AccountFlows.register(client: client, email: "alex@example.com", password: "correct horse",
                                                                  device: testDevice, kdf: testKDF)
        XCTAssertEqual(session.email, "alex@example.com")
        XCTAssertEqual(session.recoveryKey, recovery.displayString)
        XCTAssertEqual(session.encryptionKey.count, 32)
        let stored = try XCTUnwrap(server.accounts["alex@example.com"])
        XCTAssertNotEqual(stored.authKey, Data("correct horse".utf8), "the server never sees the password")

        let other = try await AccountFlows.signIn(client: try newClient(), email: "alex@example.com", password: "correct horse", device: testDevice)
        XCTAssertEqual(other.encryptionKey, session.encryptionKey)
        XCTAssertNotEqual(other.deviceID, session.deviceID)
        XCTAssertNil(other.recoveryKey, "the recovery key is not known on the new Mac until the vault is read")
    }

    func testWrongPasswordIsRefused() async throws {
        _ = try await AccountFlows.register(client: client, email: "alex@example.com", password: "right", device: testDevice, kdf: testKDF)
        do {
            _ = try await AccountFlows.signIn(client: try newClient(), email: "alex@example.com", password: "wrong", device: testDevice)
            XCTFail("signed in with a wrong password")
        } catch let error as SyncClientError {
            XCTAssertEqual(error.code, ErrorDTO.Code.invalidCredentials)
        }
    }

    func testEmailIsTrimmedAndLowercased() async throws {
        let (session, _) = try await AccountFlows.register(client: client, email: "  Alex@Example.COM ", password: "pw", device: testDevice, kdf: testKDF)
        XCTAssertEqual(session.email, "alex@example.com")
    }

    func testRecoveryKeySetsANewPassword() async throws {
        let (session, recovery) = try await AccountFlows.register(client: client, email: "a@b.co", password: "forgotten", device: testDevice, kdf: testKDF)
        let recovered = try await AccountFlows.recover(client: try newClient(), email: "a@b.co", recoveryKey: recovery,
                                                       newPassword: "new one", device: testDevice, kdf: testKDF)
        XCTAssertEqual(recovered.encryptionKey, session.encryptionKey)
        XCTAssertEqual(recovered.recoveryKey, recovery.displayString)
        let again = try await AccountFlows.signIn(client: try newClient(), email: "a@b.co", password: "new one", device: testDevice)
        XCTAssertEqual(again.encryptionKey, session.encryptionKey)
        do {
            _ = try await AccountFlows.signIn(client: try newClient(), email: "a@b.co", password: "forgotten", device: testDevice)
            XCTFail("the old password still works")
        } catch {}
    }

    func testChangingThePasswordKeepsTheKey() async throws {
        let (session, _) = try await AccountFlows.register(client: client, email: "a@b.co", password: "old", device: testDevice, kdf: testKDF)
        try await AccountFlows.changePassword(client: client, email: "a@b.co", oldPassword: "old", newPassword: "new", kdf: testKDF)
        let again = try await AccountFlows.signIn(client: try newClient(), email: "a@b.co", password: "new", device: testDevice)
        XCTAssertEqual(again.encryptionKey, session.encryptionKey)
    }

    func testRotatingTheRecoveryKeyRetiresTheOldOne() async throws {
        let (session, old) = try await AccountFlows.register(client: client, email: "a@b.co", password: "pw", device: testDevice, kdf: testKDF)
        let new = try await AccountFlows.rotateRecoveryKey(client: client, session: session, password: "pw")
        XCTAssertNotEqual(new, old)
        do {
            _ = try await AccountFlows.recover(client: try newClient(), email: "a@b.co", recoveryKey: old, newPassword: "x", device: testDevice, kdf: testKDF)
            XCTFail("the old recovery key still works")
        } catch {}
        let recovered = try await AccountFlows.recover(client: try newClient(), email: "a@b.co", recoveryKey: new, newPassword: "x", device: testDevice, kdf: testKDF)
        XCTAssertEqual(recovered.encryptionKey, session.encryptionKey)
    }

    func testOnlyHTTPSOrLocalhost() {
        XCTAssertThrowsError(try SyncClient(baseURL: URL(string: "http://sync.example.com")!, transport: server))
        XCTAssertNoThrow(try SyncClient(baseURL: URL(string: "http://localhost:8080")!, transport: server))
        XCTAssertNoThrow(try SyncClient(baseURL: URL(string: "http://127.0.0.1:8080")!, transport: server))
        XCTAssertEqual(SyncClient.defaultURL.absoluteString, "https://sync.dcstyle.info")
    }
}
