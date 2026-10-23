import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SyncServer
import TabbySyncProtocol
import XCTest

final class VaultTests: XCTestCase {
    func testNoVaultYetIs404() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            try await client.send(.get, APIPath.vault, token: session.token).assertError(.notFound, ErrorDTO.Code.notFound)
            try await client.send(.get, APIPath.vaultHead, token: session.token).assertError(.notFound, ErrorDTO.Code.notFound)
        }
    }

    func testFirstUploadWithIfMatchZeroIsRevisionOne() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            let ciphertext = randomData(1000)
            let response = try await client.putVault(ciphertext, ifMatch: 0, token: session.token)
            XCTAssertEqual(response.status, .ok, response.text)
            let put = try response.decode(VaultPutResponse.self)
            XCTAssertEqual(put.revision, 1)

            let vault = try await client.send(.get, APIPath.vault, token: session.token).decode(VaultDTO.self)
            XCTAssertEqual(vault.ciphertext, ciphertext, "round-trips byte for byte")
            XCTAssertEqual(vault.revision, 1)
            XCTAssertEqual(vault.deviceId, session.device.id)
            XCTAssertEqual(vault.modifiedAt, put.modifiedAt)

            let head = try await client.send(.get, APIPath.vaultHead, token: session.token).decode(VaultHead.self)
            XCTAssertEqual(head, vault.head)
        }
    }

    func testNextUploadNeedsTheCurrentRevision() async throws {
        try await withApp { client in
            let credentials = Credentials()
            let a = try await client.register(credentials)
            let b = try await client.login(credentials)
            let value1 = try await client.putVault(randomData(10), ifMatch: 0, token: a.token).status
            XCTAssertEqual(value1, .ok)
            let second = try await client.putVault(randomData(10), ifMatch: 1, token: b.token)
            XCTAssertEqual(try second.decode(VaultPutResponse.self).revision, 2)

            // A stale revision gets 409 and the current head, so the client can download and merge.
            let stale = try await client.putVault(randomData(10), ifMatch: 1, token: a.token)
            XCTAssertEqual(stale.status, .conflict, stale.text)
            let head = try stale.decode(VaultHead.self)
            XCTAssertEqual(head.revision, 2)
            XCTAssertEqual(head.deviceId, b.device.id)

            // Uploading "first" again when a vault exists is stale too.
            let again = try await client.putVault(randomData(10), ifMatch: 0, token: a.token)
            XCTAssertEqual(again.status, .conflict)
            XCTAssertEqual(try again.decode(VaultHead.self).revision, 2)
        }
    }

    func testIfMatchIsRequiredAndNumeric() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            try await client.putVault(randomData(10), ifMatch: nil, token: session.token)
                .assertError(.preconditionRequired, ErrorDTO.Code.preconditionRequired)
            try await client.send(.put, APIPath.vault, token: session.token, headers: [.ifMatch: "\"abc\""],
                                  json: VaultPutRequest(ciphertext: randomData(10)))
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
            // A quoted number (ETag style) is accepted.
            let quoted = try await client.send(.put, APIPath.vault, token: session.token, headers: [.ifMatch: "\"0\""],
                                               json: VaultPutRequest(ciphertext: randomData(10)))
            XCTAssertEqual(quoted.status, .ok, quoted.text)
            try await client.putVault(Data(), ifMatch: 1, token: session.token)
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
        }
    }

    func testFirstUploadWhenNoneExistsButIfMatchIsNotZeroIs409() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            let response = try await client.putVault(randomData(10), ifMatch: 3, token: session.token)
            response.assertError(.conflict, ErrorDTO.Code.conflict)
        }
    }

    /// Two uploads racing on the same revision: exactly one wins.
    func testConcurrentUploadsOnTheSameRevision() async throws {
        try await withApp { client in
            let credentials = Credentials()
            let a = try await client.register(credentials)
            let b = try await client.login(credentials)
            let value2 = try await client.putVault(randomData(10), ifMatch: 0, token: a.token).status
            XCTAssertEqual(value2, .ok)
            async let first = client.putVault(randomData(10), ifMatch: 1, token: a.token)
            async let second = client.putVault(randomData(10), ifMatch: 1, token: b.token)
            let statuses = try await [first.status, second.status]
            XCTAssertEqual(statuses.filter { $0 == .ok }.count, 1, "\(statuses)")
            XCTAssertEqual(statuses.filter { $0 == .conflict }.count, 1, "\(statuses)")
            let head = try await client.send(.get, APIPath.vaultHead, token: a.token).decode(VaultHead.self)
            XCTAssertEqual(head.revision, 2)
        }
    }

    func testVaultsAreSeparatePerAccount() async throws {
        try await withApp { client in
            let a = try await client.register(Credentials(email: "a@example.com"))
            let b = try await client.register(Credentials(email: "b@example.com"))
            let value3 = try await client.putVault(Data([1]), ifMatch: 0, token: a.token).status
            XCTAssertEqual(value3, .ok)
            try await client.send(.get, APIPath.vault, token: b.token).assertError(.notFound, ErrorDTO.Code.notFound)
            let value4 = try await client.putVault(Data([2]), ifMatch: 0, token: b.token).status
            XCTAssertEqual(value4, .ok)
            let vaultA = try await client.send(.get, APIPath.vault, token: a.token).decode(VaultDTO.self)
            XCTAssertEqual(vaultA.ciphertext, Data([1]))
        }
    }
}
