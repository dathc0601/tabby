import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TabbySyncProtocol

/// Sends a request and returns the body and response; `URLSessionTransport` in the app, an
/// in-memory server in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncClientError.invalidResponse }
        return (data, http)
    }
}

public enum SyncClientError: Error, Equatable, LocalizedError {
    /// The server URL is plain HTTP and not this Mac.
    case insecureURL(String)
    /// The server answered with an error (`ErrorDTO`).
    case server(status: Int, code: String, message: String)
    case invalidResponse

    /// The `ErrorDTO.Code` of a server error.
    public var code: String? {
        if case let .server(_, code, _) = self { return code }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case .insecureURL(let url): return "\(url) is not an HTTPS address."
        case let .server(status, code, message):
            switch code {
            case ErrorDTO.Code.invalidCredentials: return "The email or password is not right."
            case ErrorDTO.Code.emailTaken: return "There is already an account with this email."
            case ErrorDTO.Code.rateLimited: return "Too many attempts. Wait a minute and try again."
            case ErrorDTO.Code.unauthorized: return "This Mac was signed out of the account."
            default: return message.isEmpty ? "The sync server answered \(status)." : message
            }
        case .invalidResponse: return "The sync server sent something unexpected."
        }
    }
}

/// The tabby-sync-server HTTP API (`TabbySyncProtocol.APIPath`). Requires HTTPS, except for
/// this Mac (tests and a server run with Docker or `swift run`).
public final class SyncClient: @unchecked Sendable {
    /// The account server. `TABBYMAC_SYNC_URL` overrides it for tests and development only;
    /// there is no setting for it.
    public static let defaultURL = URL(string: "https://tabby-sync.dcstyle.info")!

    public static var configuredURL: URL {
        ProcessInfo.processInfo.environment["TABBYMAC_SYNC_URL"].flatMap(URL.init(string:)) ?? defaultURL
    }

    public let baseURL: URL
    public var token: String?
    private let transport: HTTPTransport

    public init(baseURL: URL = SyncClient.configuredURL, transport: HTTPTransport = URLSessionTransport(), token: String? = nil) throws {
        guard Self.isAllowed(baseURL) else { throw SyncClientError.insecureURL(baseURL.absoluteString) }
        self.baseURL = baseURL
        self.transport = transport
        self.token = token
    }

    static func isAllowed(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host ?? "")
        default: return false
        }
    }

    // MARK: Requests

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        if !query.isEmpty { c.queryItems = query }
        return c.url!
    }

    private func request(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (some Encodable)? = Optional<String>.none,
                         headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: url(path, query: query))
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = try SyncCoding.encoder.encode(body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return try await transport.send(r)
    }

    private func check(_ result: (Data, HTTPURLResponse)) throws -> Data {
        let (data, response) = result
        guard (200..<300).contains(response.statusCode) else {
            let dto = try? SyncCoding.decoder.decode(ErrorDTO.self, from: data)
            throw SyncClientError.server(status: response.statusCode, code: dto?.error ?? "", message: dto?.message ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try SyncCoding.decoder.decode(T.self, from: data) } catch { throw SyncClientError.invalidResponse }
    }

    // MARK: Account

    public func kdf(email: String) async throws -> KDFParams {
        try decode(KDFResponse.self, check(await request("GET", APIPath.accountKDF, query: [URLQueryItem(name: "email", value: email)]))).kdf
    }

    public func register(_ body: RegisterRequest) async throws -> SessionResponse {
        try decode(SessionResponse.self, check(await request("POST", APIPath.account, body: body)))
    }

    public func signIn(_ body: SessionRequest) async throws -> SessionResponse {
        try decode(SessionResponse.self, check(await request("POST", APIPath.session, body: body)))
    }

    public func recoverySignIn(_ body: RecoverySessionRequest) async throws -> RecoverySessionResponse {
        try decode(RecoverySessionResponse.self, check(await request("POST", APIPath.sessionRecovery, body: body)))
    }

    public func signOut() async throws {
        _ = try check(await request("DELETE", APIPath.session))
    }

    public func account() async throws -> AccountDTO {
        try decode(AccountDTO.self, check(await request("GET", APIPath.account)))
    }

    @discardableResult
    public func changePassword(_ body: PasswordChangeRequest) async throws -> AccountDTO {
        try decode(AccountDTO.self, check(await request("PATCH", APIPath.accountPassword, body: body)))
    }

    @discardableResult
    public func rotateRecovery(_ body: RecoveryRotateRequest) async throws -> AccountDTO {
        try decode(AccountDTO.self, check(await request("PUT", APIPath.accountRecovery, body: body)))
    }

    public func deleteAccount(_ body: DeleteAccountRequest) async throws {
        _ = try check(await request("DELETE", APIPath.account, body: body))
    }

    // MARK: Vault

    /// The vault, or nil before the first upload.
    public func vault() async throws -> VaultDTO? {
        let result = try await request("GET", APIPath.vault)
        if result.1.statusCode == 404 { return nil }
        return try decode(VaultDTO.self, check(result))
    }

    public func vaultHead() async throws -> VaultHead? {
        let result = try await request("GET", APIPath.vaultHead)
        if result.1.statusCode == 404 { return nil }
        return try decode(VaultHead.self, check(result))
    }

    public enum PutResult: Equatable {
        case saved(VaultPutResponse)
        /// Someone uploaded since `ifMatch`: download, merge, try again.
        case conflict
    }

    public func putVault(_ ciphertext: Data, ifMatch revision: Int) async throws -> PutResult {
        let result = try await request("PUT", APIPath.vault, body: VaultPutRequest(ciphertext: ciphertext),
                                       headers: [APIPath.ifMatchHeader: String(revision)])
        if result.1.statusCode == 409 { return .conflict }
        return .saved(try decode(VaultPutResponse.self, check(result)))
    }

    // MARK: Devices

    public func devices() async throws -> [DeviceDTO] {
        try decode([DeviceDTO].self, check(await request("GET", APIPath.devices)))
    }

    public func removeDevice(_ id: UUID) async throws {
        _ = try check(await request("DELETE", APIPath.device(id)))
    }
}
