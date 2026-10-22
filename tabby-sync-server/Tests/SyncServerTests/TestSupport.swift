import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SyncServer
import TabbySyncProtocol
import XCTest

/// A fixed configuration for in-process tests: SQLite in memory, a known secret.
func testConfig(rateLimitPerMinute: Int = 10, registrationsPerDay: Int = 1000, minimumScryptN: Int = 1024) -> ServerConfig {
    ServerConfig(
        database: .sqliteMemory,
        serverSecret: Data("test-secret".utf8),
        rateLimitPerMinute: rateLimitPerMinute,
        registrationsPerDay: registrationsPerDay,
        minimumScryptN: minimumScryptN,
        logLevel: .error
    )
}

/// Builds the application and runs `body` against it through HummingbirdTesting's router
/// framework (no sockets).
func withApp(
    _ config: ServerConfig = testConfig(),
    _ body: @Sendable (any TestClientProtocol) async throws -> Void
) async throws {
    let app = try await buildApplication(config)
    try await app.test(.router, body)
}

/// The values a client derives at sign-up; random bytes stand in for real keys except in the
/// end-to-end test.
struct Credentials: Sendable {
    var email: String
    var authKey = randomData(32)
    var recoveryAuthKey = randomData(32)
    var kdf = KDFParams(n: 1024, r: 8, p: 1, salt: randomData(16))
    var wrappedByPassword = randomData(60)
    var wrappedByRecovery = randomData(60)

    init(email: String = "user@example.com") {
        self.email = email
    }

    var registerRequest: RegisterRequest {
        RegisterRequest(email: email, authKey: authKey, recoveryAuthKey: recoveryAuthKey, kdf: kdf,
                        wrappedByPassword: wrappedByPassword, wrappedByRecovery: wrappedByRecovery,
                        device: DeviceInfo(name: "Mac A", model: "Mac15,3", os: "macOS 15.1"))
    }

    func sessionRequest(device: String = "Mac B") -> SessionRequest {
        SessionRequest(email: email, authKey: authKey, device: DeviceInfo(name: device, model: "Mac14,2", os: "macOS 14.6"))
    }
}

func randomData(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}

extension HTTPField.Name {
    static let xForwardedFor = HTTPField.Name("X-Forwarded-For")!
}

extension TestClientProtocol {
    /// Sends `body` as JSON (through `SyncCoding`) with an optional bearer token.
    func send(
        _ method: HTTPRequest.Method, _ uri: String, token: String? = nil, headers: HTTPFields = [:],
        json body: (some Encodable)? = Optional<Data>.none
    ) async throws -> TestResponse {
        var headers = headers
        if let token { headers[.authorization] = "Bearer \(token)" }
        var buffer: ByteBuffer?
        if let body {
            headers[.contentType] = "application/json"
            buffer = ByteBuffer(bytes: try SyncCoding.encoder.encode(body))
        }
        return try await execute(uri: uri, method: method, headers: headers, body: buffer)
    }

    func register(_ credentials: Credentials) async throws -> SessionResponse {
        let response = try await send(.post, APIPath.account, json: credentials.registerRequest)
        XCTAssertEqual(response.status, .created, response.text)
        return try response.decode(SessionResponse.self)
    }

    func login(_ credentials: Credentials, device: String = "Mac B") async throws -> SessionResponse {
        let response = try await send(.post, APIPath.session, json: credentials.sessionRequest(device: device))
        XCTAssertEqual(response.status, .ok, response.text)
        return try response.decode(SessionResponse.self)
    }

    func putVault(_ ciphertext: Data, ifMatch: Int?, token: String) async throws -> TestResponse {
        var headers: HTTPFields = [:]
        if let ifMatch { headers[.ifMatch] = String(ifMatch) }
        return try await send(.put, APIPath.vault, token: token, headers: headers,
                              json: VaultPutRequest(ciphertext: ciphertext))
    }
}

extension TestResponse {
    var text: String { String(buffer: body) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try SyncCoding.decoder.decode(T.self, from: Data(body.readableBytesView))
    }

    /// Asserts the status and that the body is an `ErrorDTO` with `code`.
    func assertError(_ status: HTTPResponse.Status, _ code: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(self.status, status, text, file: file, line: line)
        XCTAssertEqual(try? decode(ErrorDTO.self).error, code, text, file: file, line: line)
    }
}
