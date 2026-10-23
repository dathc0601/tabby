import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SyncServer
import TabbySyncProtocol
import XCTest

final class AccountTests: XCTestCase {
    func testRegisterReturns201WithATokenAndTheAccount() async throws {
        try await withApp { client in
            let credentials = Credentials(email: "  New.User@Example.COM ")
            let response = try await client.send(.post, APIPath.account, json: credentials.registerRequest)
            XCTAssertEqual(response.status, .created, response.text)
            XCTAssertEqual(response.headers[.contentType], "application/json; charset=utf-8")
            let session = try response.decode(SessionResponse.self)
            XCTAssertEqual(session.account.email, "new.user@example.com", "trimmed and lowercased")
            XCTAssertEqual(session.account.kdf, credentials.kdf)
            XCTAssertEqual(session.account.wrappedByPassword, credentials.wrappedByPassword)
            XCTAssertEqual(session.device.name, "Mac A")
            XCTAssertTrue(session.device.isCurrent)
            XCTAssertEqual(Data(base64URLEncoded: session.token)?.count, 32, "32 random bytes, base64url")
        }
    }

    func testDuplicateEmailIs409() async throws {
        try await withApp { client in
            _ = try await client.register(Credentials(email: "a@example.com"))
            let again = try await client.send(.post, APIPath.account, json: Credentials(email: "A@Example.com").registerRequest)
            again.assertError(.conflict, ErrorDTO.Code.emailTaken)
        }
    }

    func testRegisterValidatesItsInput() async throws {
        try await withApp { client in
            for email in ["", "no-at-sign", "a@b", "two@@example.com", "sp ace@example.com", "@example.com"] {
                let response = try await client.send(.post, APIPath.account, json: Credentials(email: email).registerRequest)
                response.assertError(.badRequest, ErrorDTO.Code.invalidEmail)
            }
            var shortKey = Credentials(email: "a@example.com")
            shortKey.authKey = Data(count: 8)
            try await client.send(.post, APIPath.account, json: shortKey.registerRequest)
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
            var badKDF = Credentials(email: "a@example.com")
            badKDF.kdf.name = "md5"
            try await client.send(.post, APIPath.account, json: badKDF.registerRequest)
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
            let notJSON = try await client.execute(uri: APIPath.account, method: .post, body: ByteBuffer(string: "{"))
            notJSON.assertError(.badRequest, ErrorDTO.Code.badRequest)
        }
    }

    func testKDFOfAKnownEmailIsTheStoredOne() async throws {
        try await withApp { client in
            let credentials = Credentials(email: "a@example.com")
            _ = try await client.register(credentials)
            let response = try await client.send(.get, "\(APIPath.accountKDF)?email=A%40example.com")
            XCTAssertEqual(response.status, .ok)
            XCTAssertEqual(try response.decode(KDFResponse.self).kdf, credentials.kdf)
        }
    }

    /// Unknown emails get default parameters with a salt derived from the server secret, so
    /// the answer does not reveal whether an account exists.
    func testKDFOfAnUnknownEmailIsStableAndPerEmail() async throws {
        try await withApp { client in
            func kdf(_ email: String) async throws -> KDFParams {
                let response = try await client.send(.get, "\(APIPath.accountKDF)?email=\(email)")
                XCTAssertEqual(response.status, .ok)
                return try response.decode(KDFResponse.self).kdf
            }
            let first = try await kdf("ghost@example.com")
            let value1 = try await kdf("ghost@example.com")
            XCTAssertEqual(value1, first)
            let value2 = try await kdf("GHOST@example.com")
            XCTAssertEqual(value2, first, "normalized like registration")
            let value3 = try await kdf("other@example.com").salt
            XCTAssertNotEqual(value3, first.salt)
            XCTAssertEqual(first.name, "scrypt")
            XCTAssertEqual(first.n, KDFParams.defaultN)
            XCTAssertEqual(first.r, KDFParams.defaultR)
            XCTAssertEqual(first.p, KDFParams.defaultP)
            let mac = HMAC<SHA256>.authenticationCode(for: Data("ghost@example.com".utf8),
                                                      using: SymmetricKey(data: Data("test-secret".utf8)))
            XCTAssertEqual(first.salt, Data(mac).prefix(16))
        }
    }

    func testKDFWithoutEmailIs400() async throws {
        try await withApp { client in
            try await client.send(.get, APIPath.accountKDF).assertError(.badRequest, ErrorDTO.Code.badRequest)
        }
    }

    func testLoginWithTheWrongKeyIs401() async throws {
        try await withApp { client in
            var credentials = Credentials(email: "a@example.com")
            _ = try await client.register(credentials)
            credentials.authKey = randomData(32)
            try await client.send(.post, APIPath.session, json: credentials.sessionRequest())
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            try await client.send(.post, APIPath.session, json: Credentials(email: "nobody@example.com").sessionRequest())
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
        }
    }

    func testLoginCreatesANewDevice() async throws {
        try await withApp { client in
            let credentials = Credentials(email: "a@example.com")
            let first = try await client.register(credentials)
            let second = try await client.login(credentials, device: "Mac B")
            XCTAssertNotEqual(second.token, first.token)
            XCTAssertNotEqual(second.device.id, first.device.id)
            XCTAssertEqual(second.device.name, "Mac B")
            XCTAssertEqual(second.device.model, "Mac14,2")
            XCTAssertEqual(second.account.id, first.account.id)
            XCTAssertEqual(second.account.wrappedByPassword, credentials.wrappedByPassword)
        }
    }

    func testGetAccountNeedsAValidToken() async throws {
        try await withApp { client in
            let credentials = Credentials(email: "a@example.com")
            let session = try await client.register(credentials)
            let response = try await client.send(.get, APIPath.account, token: session.token)
            XCTAssertEqual(response.status, .ok)
            let account = try response.decode(AccountDTO.self)
            XCTAssertEqual(account, session.account)
            try await client.send(.get, APIPath.account).assertError(.unauthorized, ErrorDTO.Code.unauthorized)
            try await client.send(.get, APIPath.account, token: "bogus").assertError(.unauthorized, ErrorDTO.Code.unauthorized)
            try await client.send(.get, APIPath.account, headers: [.authorization: "Basic abc"])
                .assertError(.unauthorized, ErrorDTO.Code.unauthorized)
        }
    }

    func testSignOutRevokesTheToken() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials(email: "a@example.com"))
            let response = try await client.send(.delete, APIPath.session, token: session.token)
            XCTAssertEqual(response.status, .noContent)
            try await client.send(.get, APIPath.account, token: session.token).assertError(.unauthorized, ErrorDTO.Code.unauthorized)
        }
    }

    func testPasswordChangeKeepsTheVaultReadable() async throws {
        try await withApp { client in
            var credentials = Credentials(email: "a@example.com")
            let session = try await client.register(credentials)
            let ciphertext = randomData(500)
            let value4 = try await client.putVault(ciphertext, ifMatch: 0, token: session.token).status
            XCTAssertEqual(value4, .ok)

            let newAuthKey = randomData(32)
            let newKDF = KDFParams(n: 2048, r: 8, p: 1, salt: randomData(16))
            let newWrapped = randomData(60)
            let change = PasswordChangeRequest(authKey: credentials.authKey, newAuthKey: newAuthKey, newKdf: newKDF,
                                               newWrappedByPassword: newWrapped)
            let response = try await client.send(.patch, APIPath.accountPassword, token: session.token, json: change)
            XCTAssertEqual(response.status, .ok, response.text)
            let account = try response.decode(AccountDTO.self)
            XCTAssertEqual(account.kdf, newKDF)
            XCTAssertEqual(account.wrappedByPassword, newWrapped)

            // The old password no longer signs in; the new one does, and the vault is untouched.
            try await client.send(.post, APIPath.session, json: credentials.sessionRequest())
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            credentials.authKey = newAuthKey
            let next = try await client.login(credentials)
            XCTAssertEqual(next.account.wrappedByPassword, newWrapped)
            let vault = try await client.send(.get, APIPath.vault, token: next.token).decode(VaultDTO.self)
            XCTAssertEqual(vault.ciphertext, ciphertext)
            XCTAssertEqual(vault.revision, 1)
            let kdf = try await client.send(.get, "\(APIPath.accountKDF)?email=a@example.com").decode(KDFResponse.self)
            XCTAssertEqual(kdf.kdf, newKDF)
        }
    }

    func testPasswordChangeNeedsExactlyOneValidProof() async throws {
        try await withApp { client in
            let credentials = Credentials(email: "a@example.com")
            let session = try await client.register(credentials)
            func change(authKey: Data?, recoveryAuthKey: Data?) async throws -> TestResponse {
                try await client.send(.patch, APIPath.accountPassword, token: session.token, json: PasswordChangeRequest(
                    authKey: authKey, recoveryAuthKey: recoveryAuthKey, newAuthKey: randomData(32),
                    newKdf: credentials.kdf, newWrappedByPassword: randomData(60)))
            }
            try await change(authKey: nil, recoveryAuthKey: nil).assertError(.badRequest, ErrorDTO.Code.badRequest)
            try await change(authKey: credentials.authKey, recoveryAuthKey: credentials.recoveryAuthKey)
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
            try await change(authKey: randomData(32), recoveryAuthKey: nil)
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            let value5 = try await change(authKey: nil, recoveryAuthKey: credentials.recoveryAuthKey).status
            XCTAssertEqual(value5, .ok)
        }
    }

    func testDeleteAccountCascades() async throws {
        try await withApp { client in
            let credentials = Credentials(email: "a@example.com")
            let session = try await client.register(credentials)
            let other = try await client.login(credentials)
            let value6 = try await client.putVault(randomData(100), ifMatch: 0, token: session.token).status
            XCTAssertEqual(value6, .ok)

            try await client.send(.delete, APIPath.account, token: session.token, json: DeleteAccountRequest(authKey: randomData(32)))
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            let response = try await client.send(.delete, APIPath.account, token: session.token,
                                                 json: DeleteAccountRequest(authKey: credentials.authKey))
            XCTAssertEqual(response.status, .noContent, response.text)

            for token in [session.token, other.token] {
                try await client.send(.get, APIPath.account, token: token).assertError(.unauthorized, ErrorDTO.Code.unauthorized)
            }
            try await client.send(.post, APIPath.session, json: credentials.sessionRequest())
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            let kdf = try await client.send(.get, "\(APIPath.accountKDF)?email=a@example.com").decode(KDFResponse.self)
            XCTAssertNotEqual(kdf.kdf, credentials.kdf, "the account is gone")

            // The email is free again and starts without a vault.
            let fresh = try await client.register(Credentials(email: "a@example.com"))
            try await client.send(.get, APIPath.vault, token: fresh.token).assertError(.notFound, ErrorDTO.Code.notFound)
            let devices = try await client.send(.get, APIPath.devices, token: fresh.token).decode([DeviceDTO].self)
            XCTAssertEqual(devices.count, 1)
        }
    }
}

extension Data {
    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
