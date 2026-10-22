import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SyncServer
import TabbySyncProtocol
import XCTest

final class DeviceTests: XCTestCase {
    func testDeviceListAndRevoke() async throws {
        try await withApp { client in
            let credentials = Credentials()
            let a = try await client.register(credentials)
            try await Task.sleep(for: .milliseconds(5)) // timestamps have millisecond precision
            let b = try await client.login(credentials, device: "Mac B")

            let response = try await client.send(.get, APIPath.devices, token: a.token)
            XCTAssertEqual(response.status, .ok)
            let devices = try response.decode([DeviceDTO].self)
            XCTAssertEqual(devices.map(\.name), ["Mac A", "Mac B"], "oldest first")
            XCTAssertEqual(devices.map(\.isCurrent), [true, false])

            let revoke = try await client.send(.delete, APIPath.device(b.device.id), token: a.token)
            XCTAssertEqual(revoke.status, .noContent, revoke.text)
            try await client.send(.get, APIPath.vault, token: b.token).assertError(.unauthorized, ErrorDTO.Code.unauthorized)
            let remaining = try await client.send(.get, APIPath.devices, token: a.token).decode([DeviceDTO].self)
            XCTAssertEqual(remaining.map(\.id), [a.device.id])

            try await client.send(.delete, APIPath.device(b.device.id), token: a.token)
                .assertError(.notFound, ErrorDTO.Code.notFound)
            try await client.send(.delete, "\(APIPath.devices)/not-a-uuid", token: a.token)
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
        }
    }

    func testRevokingTheCurrentDeviceSignsOut() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            let response = try await client.send(.delete, APIPath.device(session.device.id), token: session.token)
            XCTAssertEqual(response.status, .noContent)
            try await client.send(.get, APIPath.account, token: session.token).assertError(.unauthorized, ErrorDTO.Code.unauthorized)
        }
    }

    func testAnotherAccountsDeviceCannotBeRevoked() async throws {
        try await withApp { client in
            let a = try await client.register(Credentials(email: "a@example.com"))
            let b = try await client.register(Credentials(email: "b@example.com"))
            try await client.send(.delete, APIPath.device(b.device.id), token: a.token)
                .assertError(.notFound, ErrorDTO.Code.notFound)
            let value1 = try await client.send(.get, APIPath.account, token: b.token).status
            XCTAssertEqual(value1, .ok)
        }
    }

    func testUsingATokenUpdatesLastSeen() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            try await Task.sleep(for: .milliseconds(20))
            _ = try await client.send(.get, APIPath.account, token: session.token)
            let device = try await client.send(.get, APIPath.devices, token: session.token).decode([DeviceDTO].self)[0]
            XCTAssertGreaterThan(device.lastSeenAt, session.device.lastSeenAt)
            XCTAssertEqual(device.createdAt, session.device.createdAt)
        }
    }
}

final class RecoveryTests: XCTestCase {
    static func recover(_ client: any TestClientProtocol, _ credentials: Credentials) async throws -> RecoverySessionResponse {
        let request = RecoverySessionRequest(email: credentials.email, recoveryAuthKey: credentials.recoveryAuthKey,
                                             device: DeviceInfo(name: "New Mac", model: "Mac16,1", os: "macOS 15.2"))
        let response = try await client.send(.post, APIPath.sessionRecovery, json: request)
        XCTAssertEqual(response.status, .ok, response.text)
        return try response.decode(RecoverySessionResponse.self)
    }

    func testRecoverySignInGivesALimitedToken() async throws {
        try await withApp { client in
            let credentials = Credentials()
            let owner = try await client.register(credentials)
            let value2 = try await client.putVault(Data([7]), ifMatch: 0, token: owner.token).status
            XCTAssertEqual(value2, .ok)

            let session = try await Self.recover(client, credentials)
            XCTAssertEqual(session.wrappedByRecovery, credentials.wrappedByRecovery)
            XCTAssertEqual(session.device.name, "New Mac")

            let value3 = try await client.send(.get, APIPath.account, token: session.token).status
            XCTAssertEqual(value3, .ok)
            let vault = try await client.send(.get, APIPath.vault, token: session.token).decode(VaultDTO.self)
            XCTAssertEqual(vault.ciphertext, Data([7]))

            try await client.putVault(Data([8]), ifMatch: 1, token: session.token).assertError(.forbidden, ErrorDTO.Code.forbidden)
            for (method, path) in [(HTTPRequest.Method.get, APIPath.vaultHead), (.get, APIPath.devices), (.delete, APIPath.session)] {
                try await client.send(method, path, token: session.token).assertError(.forbidden, ErrorDTO.Code.forbidden)
            }
            try await client.send(.put, APIPath.accountRecovery, token: session.token, json: RecoveryRotateRequest(
                authKey: credentials.authKey, newRecoveryAuthKey: randomData(32), newWrappedByRecovery: randomData(60)))
                .assertError(.forbidden, ErrorDTO.Code.forbidden)
        }
    }

    func testRecoverySignInWithTheWrongKeyIs401() async throws {
        try await withApp { client in
            var credentials = Credentials()
            _ = try await client.register(credentials)
            credentials.recoveryAuthKey = randomData(32)
            let request = RecoverySessionRequest(email: credentials.email, recoveryAuthKey: credentials.recoveryAuthKey,
                                                 device: DeviceInfo(name: "x", model: "x", os: "x"))
            try await client.send(.post, APIPath.sessionRecovery, json: request)
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
        }
    }

    func testSettingANewPasswordUpgradesTheRecoveryToken() async throws {
        try await withApp { client in
            var credentials = Credentials()
            let owner = try await client.register(credentials)
            let value4 = try await client.putVault(Data([7]), ifMatch: 0, token: owner.token).status
            XCTAssertEqual(value4, .ok)
            let session = try await Self.recover(client, credentials)

            let newAuthKey = randomData(32)
            let change = PasswordChangeRequest(recoveryAuthKey: credentials.recoveryAuthKey, newAuthKey: newAuthKey,
                                               newKdf: credentials.kdf, newWrappedByPassword: randomData(60))
            let response = try await client.send(.patch, APIPath.accountPassword, token: session.token, json: change)
            XCTAssertEqual(response.status, .ok, response.text)

            // Same token, now full scope.
            let value5 = try await client.putVault(Data([8]), ifMatch: 1, token: session.token).status
            XCTAssertEqual(value5, .ok)
            let value6 = try await client.send(.get, APIPath.devices, token: session.token).status
            XCTAssertEqual(value6, .ok)
            credentials.authKey = newAuthKey
            _ = try await client.login(credentials)
        }
    }

    func testRecoveryTokenCannotChangeThePasswordWithAWrongKey() async throws {
        try await withApp { client in
            let credentials = Credentials()
            _ = try await client.register(credentials)
            let session = try await Self.recover(client, credentials)
            let change = PasswordChangeRequest(recoveryAuthKey: randomData(32), newAuthKey: randomData(32),
                                               newKdf: credentials.kdf, newWrappedByPassword: randomData(60))
            try await client.send(.patch, APIPath.accountPassword, token: session.token, json: change)
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            try await client.putVault(Data([8]), ifMatch: 0, token: session.token).assertError(.forbidden, ErrorDTO.Code.forbidden)
        }
    }

    func testRotatingTheRecoveryKey() async throws {
        try await withApp { client in
            var credentials = Credentials()
            let session = try await client.register(credentials)
            try await Task.sleep(for: .milliseconds(5))
            let newRecoveryAuthKey = randomData(32)
            let newWrapped = randomData(60)

            try await client.send(.put, APIPath.accountRecovery, token: session.token, json: RecoveryRotateRequest(
                authKey: randomData(32), newRecoveryAuthKey: newRecoveryAuthKey, newWrappedByRecovery: newWrapped))
                .assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            let response = try await client.send(.put, APIPath.accountRecovery, token: session.token, json: RecoveryRotateRequest(
                authKey: credentials.authKey, newRecoveryAuthKey: newRecoveryAuthKey, newWrappedByRecovery: newWrapped))
            XCTAssertEqual(response.status, .ok, response.text)
            XCTAssertGreaterThan(try response.decode(AccountDTO.self).recoveryUpdatedAt, session.account.recoveryUpdatedAt)

            // The old key no longer works; the new one does and returns the new wrap.
            let old = RecoverySessionRequest(email: credentials.email, recoveryAuthKey: credentials.recoveryAuthKey,
                                             device: DeviceInfo(name: "x", model: "x", os: "x"))
            try await client.send(.post, APIPath.sessionRecovery, json: old).assertError(.unauthorized, ErrorDTO.Code.invalidCredentials)
            credentials.recoveryAuthKey = newRecoveryAuthKey
            let recovered = try await Self.recover(client, credentials)
            XCTAssertEqual(recovered.wrappedByRecovery, newWrapped)
        }
    }
}
