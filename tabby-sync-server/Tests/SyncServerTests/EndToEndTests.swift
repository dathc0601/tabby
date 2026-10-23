import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SyncServer
import TabbySyncProtocol
import XCTest

/// The whole key hierarchy against the real server: what a second Mac does with nothing but
/// the email and the password.
final class EndToEndTests: XCTestCase {
    func testSecondDeviceOpensTheVaultWithOnlyEmailAndPassword() async throws {
        try await withApp { client in
            let email = "e2e@example.com"
            let password = "correct horse battery staple"
            let snapshot = SyncSnapshot(
                createdAt: Date(timeIntervalSince1970: 1_790_000_000.25),
                deviceId: "mac-a",
                settings: TextSection(updatedAt: Date(timeIntervalSince1970: 1_790_000_000), text: "terminal:\n  fontSize: 15\n"),
                profiles: ItemSection(items: [SyncItem(id: "p1", modifiedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                                       value: ["name": "prod", "type": "ssh", "options": ["host": "10.0.0.5"]])]),
                secrets: ItemSection(items: [SyncItem(id: "ssh:password|ssh@10.0.0.5:22|root",
                                                      modifiedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                                      value: ["value": "hunter2"])])
            )

            // Mac A signs up.
            let kdf = KDFParams.generate(n: 1024)
            let keys = try VaultCrypto.passwordKeys(password: password, kdf: kdf)
            let encKey = VaultCrypto.generateEncryptionKey()
            let recovery = RecoveryKey.generate()
            let register = RegisterRequest(
                email: email, authKey: keys.authKey, recoveryAuthKey: recovery.authKey, kdf: kdf,
                wrappedByPassword: try VaultCrypto.wrap(encKey, with: keys.wrapKey),
                wrappedByRecovery: try VaultCrypto.wrap(encKey, with: recovery.wrapKey),
                device: DeviceInfo(name: "Mac A", model: "Mac15,3", os: "macOS 15.1"))
            let created = try await client.send(.post, APIPath.account, json: register)
            XCTAssertEqual(created.status, .created, created.text)
            let a = try created.decode(SessionResponse.self)
            let blob = try VaultCrypto.sealSnapshot(snapshot, using: encKey)
            let value1 = try await client.putVault(blob, ifMatch: 0, token: a.token).status
            XCTAssertEqual(value1, .ok)

            // Mac B knows only the email and the password.
            let kdfB = try await client.send(.get, "\(APIPath.accountKDF)?email=\(email)").decode(KDFResponse.self).kdf
            let keysB = try VaultCrypto.passwordKeys(password: password, kdf: kdfB)
            let login = SessionRequest(email: email, authKey: keysB.authKey,
                                       device: DeviceInfo(name: "Mac B", model: "Mac14,2", os: "macOS 14.6"))
            let signedIn = try await client.send(.post, APIPath.session, json: login)
            XCTAssertEqual(signedIn.status, .ok, signedIn.text)
            let b = try signedIn.decode(SessionResponse.self)
            let encKeyB = try VaultCrypto.unwrap(b.account.wrappedByPassword, with: keysB.wrapKey)
            let vault = try await client.send(.get, APIPath.vault, token: b.token).decode(VaultDTO.self)
            XCTAssertEqual(try VaultCrypto.openSnapshot(vault.ciphertext, using: encKeyB), snapshot)

            // A wrong password derives a key the server refuses.
            let wrong = try VaultCrypto.passwordKeys(password: "wrong", kdf: kdfB)
            let refused = try await client.send(.post, APIPath.session, json: SessionRequest(
                email: email, authKey: wrong.authKey, device: login.device))
            XCTAssertEqual(refused.status, .unauthorized)

            // Forgot the password: the recovery key opens the same vault, then sets a new password.
            let typed = try RecoveryKey(parsing: recovery.displayString.lowercased())
            let recoveryResponse = try await client.send(.post, APIPath.sessionRecovery, json: RecoverySessionRequest(
                email: email, recoveryAuthKey: typed.authKey, device: DeviceInfo(name: "Mac C", model: "Mac16,1", os: "macOS 15.2")))
            XCTAssertEqual(recoveryResponse.status, .ok, recoveryResponse.text)
            let c = try recoveryResponse.decode(RecoverySessionResponse.self)
            let encKeyC = try VaultCrypto.unwrap(c.wrappedByRecovery, with: typed.wrapKey)
            let vaultC = try await client.send(.get, APIPath.vault, token: c.token).decode(VaultDTO.self)
            XCTAssertEqual(try VaultCrypto.openSnapshot(vaultC.ciphertext, using: encKeyC), snapshot)

            let newKDF = KDFParams.generate(n: 1024)
            let newKeys = try VaultCrypto.passwordKeys(password: "a new password", kdf: newKDF)
            let change = PasswordChangeRequest(recoveryAuthKey: typed.authKey, newAuthKey: newKeys.authKey, newKdf: newKDF,
                                               newWrappedByPassword: try VaultCrypto.wrap(encKeyC, with: newKeys.wrapKey))
            let value2 = try await client.send(.patch, APIPath.accountPassword, token: c.token, json: change).status
            XCTAssertEqual(value2, .ok)

            // Mac A's next sign-in uses the new password and still opens the same vault.
            let kdfD = try await client.send(.get, "\(APIPath.accountKDF)?email=\(email)").decode(KDFResponse.self).kdf
            XCTAssertEqual(kdfD, newKDF)
            let keysD = try VaultCrypto.passwordKeys(password: "a new password", kdf: kdfD)
            let d = try await client.send(.post, APIPath.session, json: SessionRequest(
                email: email, authKey: keysD.authKey, device: login.device)).decode(SessionResponse.self)
            let encKeyD = try VaultCrypto.unwrap(d.account.wrappedByPassword, with: keysD.wrapKey)
            let vaultD = try await client.send(.get, APIPath.vault, token: d.token).decode(VaultDTO.self)
            XCTAssertEqual(try VaultCrypto.openSnapshot(vaultD.ciphertext, using: encKeyD), snapshot)
        }
    }
}
