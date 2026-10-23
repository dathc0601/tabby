import Foundation
// l10n-ignore-file: an in-memory test server, nothing here is shown to users
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TabbySyncProtocol

/// An in-memory stand-in for tabby-sync-server with the same HTTP semantics (status codes,
/// recovery-scoped tokens, If-Match compare-and-swap), for tests and for running the app
/// without a server (`TABBYMAC_SYNC_URL=memory:`). It keeps raw auth keys, so it is never a
/// real server: tabby-sync-server is.
public final class InMemorySyncServer: HTTPTransport, @unchecked Sendable {
    public struct Account {
        var id = UUID()
        var email: String
        var kdf: KDFParams
        public var authKey: Data
        var recoveryAuthKey: Data
        var wrappedByPassword: Data
        var wrappedByRecovery: Data
        var createdAt = Date()
        var recoveryUpdatedAt = Date()
        var dto: AccountDTO {
            AccountDTO(id: id, email: email, createdAt: createdAt, kdf: kdf, wrappedByPassword: wrappedByPassword,
                       recoveryUpdatedAt: recoveryUpdatedAt)
        }
    }

    public struct Device {
        var id = UUID()
        var accountID: UUID
        var token: String
        var recoveryOnly: Bool
        var info: DeviceInfo
        var createdAt = Date()
    }

    private let lock = NSLock()
    public var accounts: [String: Account] = [:]
    public var devices: [UUID: Device] = [:]
    public var vaults: [UUID: VaultDTO] = [:]
    /// Requests seen, as "METHOD /path".
    public var log: [String] = []
    /// Fails the next PUT /v1/vault with 409 as if another Mac had uploaded first.
    public var injectConflict = false

    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.lock()
        defer { lock.unlock() }
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        log.append("\(method) \(url.path)")
        let (status, body) = handle(method: method, path: url.path, query: url.query, request: request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (body, response)
    }

    private func json(_ value: some Encodable, _ status: Int = 200) -> (Int, Data) {
        (status, (try? SyncCoding.encoder.encode(value)) ?? Data())
    }

    private func error(_ status: Int, _ code: String) -> (Int, Data) {
        json(ErrorDTO(error: code, message: code), status)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ request: URLRequest) -> T? {
        request.httpBody.flatMap { try? SyncCoding.decoder.decode(T.self, from: $0) }
    }

    private func device(for request: URLRequest) -> Device? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") else { return nil }
        let token = String(header.dropFirst(7))
        return devices.values.first { $0.token == token }
    }

    private func newDevice(_ account: Account, _ info: DeviceInfo, recoveryOnly: Bool) -> Device {
        let d = Device(accountID: account.id, token: UUID().uuidString, recoveryOnly: recoveryOnly, info: info)
        devices[d.id] = d
        return d
    }

    private func dto(_ d: Device, current: Device?) -> DeviceDTO {
        DeviceDTO(id: d.id, name: d.info.name, model: d.info.model, os: d.info.os, createdAt: d.createdAt, lastSeenAt: d.createdAt,
                  isCurrent: d.id == current?.id)
    }

    private func handle(method: String, path: String, query: String?, request: URLRequest) -> (Int, Data) {
        switch (method, path) {
        case ("GET", APIPath.accountKDF):
            let email = (query ?? "").replacingOccurrences(of: "email=", with: "").removingPercentEncoding ?? ""
            let kdf = accounts[email]?.kdf ?? KDFParams(n: 1024, r: 8, p: 1, salt: Data(email.utf8.prefix(16)) + Data(count: 1))
            return json(KDFResponse(kdf: kdf))
        case ("POST", APIPath.account):
            guard let r = decode(RegisterRequest.self, request) else { return error(400, ErrorDTO.Code.badRequest) }
            guard accounts[r.email] == nil else { return error(409, ErrorDTO.Code.emailTaken) }
            let a = Account(email: r.email, kdf: r.kdf, authKey: r.authKey, recoveryAuthKey: r.recoveryAuthKey,
                            wrappedByPassword: r.wrappedByPassword, wrappedByRecovery: r.wrappedByRecovery)
            accounts[r.email] = a
            let d = newDevice(a, r.device, recoveryOnly: false)
            return json(SessionResponse(token: d.token, account: a.dto, device: dto(d, current: d)), 201)
        case ("POST", APIPath.session):
            guard let r = decode(SessionRequest.self, request), let a = accounts[r.email], a.authKey == r.authKey else {
                return error(401, ErrorDTO.Code.invalidCredentials)
            }
            let d = newDevice(a, r.device, recoveryOnly: false)
            return json(SessionResponse(token: d.token, account: a.dto, device: dto(d, current: d)))
        case ("POST", APIPath.sessionRecovery):
            guard let r = decode(RecoverySessionRequest.self, request), let a = accounts[r.email], a.recoveryAuthKey == r.recoveryAuthKey else {
                return error(401, ErrorDTO.Code.invalidCredentials)
            }
            let d = newDevice(a, r.device, recoveryOnly: true)
            return json(RecoverySessionResponse(token: d.token, account: a.dto, device: dto(d, current: d), wrappedByRecovery: a.wrappedByRecovery))
        default:
            break
        }
        guard var current = device(for: request), var account = accounts.values.first(where: { $0.id == current.accountID }) else {
            return error(401, ErrorDTO.Code.unauthorized)
        }
        let recoveryAllowed: Set<String> = ["GET \(APIPath.account)", "GET \(APIPath.vault)", "PATCH \(APIPath.accountPassword)"]
        if current.recoveryOnly && !recoveryAllowed.contains("\(method) \(path)") { return error(403, ErrorDTO.Code.forbidden) }
        switch (method, path) {
        case ("DELETE", APIPath.session):
            devices[current.id] = nil
            return (204, Data())
        case ("GET", APIPath.account):
            return json(account.dto)
        case ("PATCH", APIPath.accountPassword):
            guard let r = decode(PasswordChangeRequest.self, request) else { return error(400, ErrorDTO.Code.badRequest) }
            let ok = (r.authKey.map { $0 == account.authKey } ?? false) || (r.recoveryAuthKey.map { $0 == account.recoveryAuthKey } ?? false)
            guard ok else { return error(401, ErrorDTO.Code.invalidCredentials) }
            account.authKey = r.newAuthKey
            account.kdf = r.newKdf
            account.wrappedByPassword = r.newWrappedByPassword
            accounts[account.email] = account
            current.recoveryOnly = false
            devices[current.id] = current
            return json(account.dto)
        case ("PUT", APIPath.accountRecovery):
            guard let r = decode(RecoveryRotateRequest.self, request), r.authKey == account.authKey else { return error(401, ErrorDTO.Code.invalidCredentials) }
            account.recoveryAuthKey = r.newRecoveryAuthKey
            account.wrappedByRecovery = r.newWrappedByRecovery
            account.recoveryUpdatedAt = Date()
            accounts[account.email] = account
            return json(account.dto)
        case ("DELETE", APIPath.account):
            guard let r = decode(DeleteAccountRequest.self, request), r.authKey == account.authKey else { return error(401, ErrorDTO.Code.invalidCredentials) }
            accounts[account.email] = nil
            vaults[account.id] = nil
            devices = devices.filter { $0.value.accountID != account.id }
            return (204, Data())
        case ("GET", APIPath.vault):
            guard let v = vaults[account.id] else { return error(404, ErrorDTO.Code.notFound) }
            return json(v)
        case ("GET", APIPath.vaultHead):
            guard let v = vaults[account.id] else { return error(404, ErrorDTO.Code.notFound) }
            return json(v.head)
        case ("PUT", APIPath.vault):
            guard let header = request.value(forHTTPHeaderField: APIPath.ifMatchHeader), let expected = Int(header) else {
                return error(428, ErrorDTO.Code.preconditionRequired)
            }
            guard let r = decode(VaultPutRequest.self, request) else { return error(400, ErrorDTO.Code.badRequest) }
            let currentRevision = vaults[account.id]?.revision ?? 0
            if injectConflict || expected != currentRevision {
                injectConflict = false
                if let v = vaults[account.id] { return json(v.head, 409) }
                return error(409, ErrorDTO.Code.conflict)
            }
            let v = VaultDTO(revision: currentRevision + 1, modifiedAt: Date(), deviceId: current.id, ciphertext: r.ciphertext)
            vaults[account.id] = v
            return json(VaultPutResponse(revision: v.revision, modifiedAt: v.modifiedAt))
        case ("GET", APIPath.devices):
            return json(devices.values.filter { $0.accountID == account.id }.map { dto($0, current: current) })
        default:
            if method == "DELETE", path.hasPrefix(APIPath.devices + "/"), let id = UUID(uuidString: String(path.dropFirst(APIPath.devices.count + 1))) {
                guard devices[id]?.accountID == account.id else { return error(404, ErrorDTO.Code.notFound) }
                devices[id] = nil
                return (204, Data())
            }
            return error(404, ErrorDTO.Code.notFound)
        }
    }
}
