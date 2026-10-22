import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SyncServer
import TabbySyncProtocol
import XCTest

final class LimitTests: XCTestCase {
    func testEleventhLoginInAMinuteIs429() async throws {
        try await withApp { client in
            let credentials = Credentials()
            for _ in 0..<10 {
                let response = try await client.send(.post, APIPath.session, headers: [.xForwardedFor: "203.0.113.7, 10.0.0.1"],
                                                     json: credentials.sessionRequest())
                XCTAssertEqual(response.status, .unauthorized, "no account yet, but not limited")
            }
            let limited = try await client.send(.post, APIPath.session, headers: [.xForwardedFor: "203.0.113.7"],
                                                json: credentials.sessionRequest())
            limited.assertError(.tooManyRequests, ErrorDTO.Code.rateLimited)
            XCTAssertNotNil(limited.headers[.retryAfter])

            // Another client address has its own budget, and so does registration.
            let other = try await client.send(.post, APIPath.session, headers: [.xForwardedFor: "198.51.100.1"],
                                              json: credentials.sessionRequest())
            XCTAssertEqual(other.status, .unauthorized)
            let register = try await client.send(.post, APIPath.account, headers: [.xForwardedFor: "203.0.113.7"],
                                                 json: credentials.registerRequest)
            XCTAssertEqual(register.status, .created)
        }
    }

    func testRegistrationAndRecoveryAreRateLimitedToo() async throws {
        try await withApp(testConfig(rateLimitPerMinute: 2)) { client in
            for index in 0..<2 {
                _ = try await client.register(Credentials(email: "u\(index)@example.com"))
            }
            try await client.send(.post, APIPath.account, json: Credentials(email: "u3@example.com").registerRequest)
                .assertError(.tooManyRequests, ErrorDTO.Code.rateLimited)
            let recovery = RecoverySessionRequest(email: "u0@example.com", recoveryAuthKey: randomData(32),
                                                  device: DeviceInfo(name: "x", model: "x", os: "x"))
            for _ in 0..<2 {
                let value1 = try await client.send(.post, APIPath.sessionRecovery, json: recovery).status
                XCTAssertEqual(value1, .unauthorized)
            }
            try await client.send(.post, APIPath.sessionRecovery, json: recovery)
                .assertError(.tooManyRequests, ErrorDTO.Code.rateLimited)
        }
    }

    /// Open registration on a small host: a daily cap per address on top of the per-minute one.
    func testRegistrationsPerDayAreCapped() async throws {
        try await withApp(testConfig(rateLimitPerMinute: 100, registrationsPerDay: 2)) { client in
            for index in 0..<2 {
                _ = try await client.register(Credentials(email: "d\(index)@example.com"))
            }
            try await client.send(.post, APIPath.account, json: Credentials(email: "d3@example.com").registerRequest)
                .assertError(.tooManyRequests, ErrorDTO.Code.rateLimited)
        }
    }

    /// Accounts can't be created (or re-keyed) with a work factor below the client minimum.
    func testWeakKeyDerivationIsRefused() async throws {
        try await withApp(testConfig(minimumScryptN: KDFParams.minimumN)) { client in
            try await client.send(.post, APIPath.account, json: Credentials(email: "weak@example.com").registerRequest)
                .assertError(.badRequest, ErrorDTO.Code.badRequest)
        }
    }

    func testBodiesOverTheLimitAre413() async throws {
        try await withApp { client in
            let session = try await client.register(Credentials())
            // 64 KB for ordinary routes.
            let big = SessionRequest(email: String(repeating: "a", count: 70_000), authKey: Data(), device: DeviceInfo(name: "", model: "", os: ""))
            try await client.send(.post, APIPath.session, json: big).assertError(.contentTooLarge, ErrorDTO.Code.payloadTooLarge)
            // The vault takes more than 64 KB...
            let megabyte = try await client.putVault(randomData(1_000_000), ifMatch: 0, token: session.token)
            XCTAssertEqual(megabyte.status, .ok, megabyte.text)
            // ...but not more than 25 MiB of JSON (20 MB base64-encodes to 26.7 MB).
            try await client.putVault(randomData(20_000_000), ifMatch: 1, token: session.token)
                .assertError(.contentTooLarge, ErrorDTO.Code.payloadTooLarge)
        }
    }

    func testUnknownRoutesAre404() async throws {
        try await withApp { client in
            let value2 = try await client.send(.get, "/v1/nope").status
            XCTAssertEqual(value2, .notFound)
        }
    }
}

final class ConfigTests: XCTestCase {
    func testDefaults() throws {
        let (config, warnings) = try ServerConfig.fromEnvironment([:])
        XCTAssertEqual(config.hostname, "0.0.0.0")
        XCTAssertEqual(config.port, 8080)
        XCTAssertEqual(config.database, .sqlite(path: "./sync.sqlite"))
        XCTAssertEqual(config.serverSecret.count, 32, "random per process")
        XCTAssertNotEqual(config.serverSecret, try ServerConfig.fromEnvironment([:]).config.serverSecret)
        XCTAssertEqual(config.rateLimitPerMinute, 10)
        XCTAssertTrue(warnings.contains { $0.contains("SERVER_SECRET") }, "\(warnings)")
    }

    func testReadsTheEnvironment() throws {
        let (config, warnings) = try ServerConfig.fromEnvironment([
            "PORT": "9000", "HOSTNAME": "127.0.0.1", "DATABASE_URL": "postgres://u:p@db:5432/sync",
            "SERVER_SECRET": "0123456789abcdef0123456789abcdef", "LOG_LEVEL": "debug",
        ])
        XCTAssertEqual(config.port, 9000)
        XCTAssertEqual(config.hostname, "127.0.0.1")
        XCTAssertEqual(config.database, .postgres(url: "postgres://u:p@db:5432/sync"))
        XCTAssertEqual(config.serverSecret, Data("0123456789abcdef0123456789abcdef".utf8))
        XCTAssertEqual(config.logLevel, .debug)
        XCTAssertEqual(warnings, [])

        let sqlite = try ServerConfig.fromEnvironment(["SQLITE_PATH": "/data/sync.sqlite", "SERVER_SECRET": "x"]).config
        XCTAssertEqual(sqlite.database, .sqlite(path: "/data/sync.sqlite"))
    }

    func testProductionNeedsASecret() {
        XCTAssertThrowsError(try ServerConfig.fromEnvironment(["ENVIRONMENT": "production"]))
        XCTAssertNoThrow(try ServerConfig.fromEnvironment(["ENVIRONMENT": "production", "SERVER_SECRET": "s3cret"]))
        XCTAssertThrowsError(try ServerConfig.fromEnvironment(["PORT": "eighty"]))
    }
}
