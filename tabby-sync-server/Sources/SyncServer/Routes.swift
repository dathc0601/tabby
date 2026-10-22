import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent
import SQLKit
import TabbySyncProtocol

/// The `/v1` API (see `APIPath` in TabbySyncProtocol for the contract).
struct SyncAPI: Sendable {
    let fluent: Fluent
    let serverSecret: Data
    let minimumScryptN: Int

    var db: any Database { fluent.db() }

    func addRoutes(to router: Router<SyncRequestContext>, rateLimiter: RateLimiter, registrationLimiter: RateLimiter) {
        router.group("v1").get("account/kdf") { request, _ in try await kdf(request) }

        let rateLimited = router.group("v1").add(middleware: RateLimitMiddleware(limiter: rateLimiter))
        rateLimited.add(middleware: RateLimitMiddleware(limiter: registrationLimiter))
            .post("account") { request, context in try await register(request, context) }
        rateLimited.post("session") { request, context in try await signIn(request, context) }
        rateLimited.post("session/recovery") { request, context in try await recoverySignIn(request, context) }

        // A recovery-scoped token may read the account and the vault and set a new password.
        let recoveryAllowed = router.group("v1").add(middleware: AuthMiddleware(fluent: fluent, allowRecoveryScope: true))
        recoveryAllowed.get("account") { _, context in try jsonResponse(context.requireAuth().account.dto) }
        recoveryAllowed.get("vault") { _, context in try await vault(context) }
        recoveryAllowed.patch("account/password") { request, context in try await changePassword(request, context) }

        let signedIn = router.group("v1").add(middleware: AuthMiddleware(fluent: fluent, allowRecoveryScope: false))
        signedIn.delete("session") { _, context in try await signOut(context) }
        signedIn.delete("account") { request, context in try await deleteAccount(request, context) }
        signedIn.put("account/recovery") { request, context in try await rotateRecovery(request, context) }
        signedIn.get("vault/head") { _, context in try await vaultHead(context) }
        signedIn.put("vault") { request, context in try await putVault(request, context) }
        signedIn.get("devices") { _, context in try await devices(context) }
        signedIn.delete("devices/:id") { _, context in try await deleteDevice(context) }
    }

    // MARK: Account

    func kdf(_ request: Request) async throws -> Response {
        guard let raw = request.uri.queryParameters["email"].map(String.init), !raw.isEmpty else {
            throw APIError.badRequest("The email query parameter is missing.")
        }
        let email = Security.normalizeEmail(raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let account = try await Account.query(on: db).filter(\.$email == email).first() {
            return try jsonResponse(KDFResponse(kdf: account.kdf))
        }
        return try jsonResponse(KDFResponse(kdf: Security.fakeKDF(email: email, secret: serverSecret)))
    }

    func register(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let body = try await request.decode(as: RegisterRequest.self, context: context)
        guard let email = Security.normalizeEmail(body.email) else { throw APIError.invalidEmail() }
        try validateAuthKey(body.authKey, "authKey")
        try validateAuthKey(body.recoveryAuthKey, "recoveryAuthKey")
        try validateKDF(body.kdf)
        try validateWrappedKey(body.wrappedByPassword, "wrappedByPassword")
        try validateWrappedKey(body.wrappedByRecovery, "wrappedByRecovery")
        try validateDevice(body.device)

        if try await Account.query(on: db).filter(\.$email == email).first() != nil {
            throw APIError.emailTaken()
        }
        let now = Security.now()
        let account = Account()
        account.email = email
        account.keySalt = VaultCrypto.randomBytes(Security.saltByteCount)
        account.authKeyHash = Security.hashKey(body.authKey, salt: account.keySalt)
        account.recoveryAuthKeyHash = Security.hashKey(body.recoveryAuthKey, salt: account.keySalt)
        account.kdf = body.kdf
        account.wrappedByPassword = body.wrappedByPassword
        account.wrappedByRecovery = body.wrappedByRecovery
        account.createdAt = now
        account.recoveryUpdatedAt = now
        let (device, token) = makeDevice(body.device, scope: .full, now: now)
        do {
            try await db.transaction { db in
                try await account.create(on: db)
                device.accountID = try account.requireID()
                try await device.create(on: db)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw APIError.emailTaken()
        }
        context.logger.info("Registered account \(account.id!)")
        return try jsonResponse(SessionResponse(token: token, account: account.dto, device: device.dto(currentDeviceID: device.id)),
                                status: .created)
    }

    func signIn(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let body = try await request.decode(as: SessionRequest.self, context: context)
        try validateDevice(body.device)
        let account = try await verifiedAccount(email: body.email) { account in
            Security.verifyKey(body.authKey, salt: account.keySalt, hash: account.authKeyHash)
        }
        let (device, token) = makeDevice(body.device, scope: .full, now: Security.now())
        device.accountID = try account.requireID()
        try await device.create(on: db)
        return try jsonResponse(SessionResponse(token: token, account: account.dto, device: device.dto(currentDeviceID: device.id)))
    }

    func recoverySignIn(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let body = try await request.decode(as: RecoverySessionRequest.self, context: context)
        try validateDevice(body.device)
        let account = try await verifiedAccount(email: body.email) { account in
            Security.verifyKey(body.recoveryAuthKey, salt: account.keySalt, hash: account.recoveryAuthKeyHash)
        }
        let (device, token) = makeDevice(body.device, scope: .recovery, now: Security.now())
        device.accountID = try account.requireID()
        try await device.create(on: db)
        context.logger.info("Recovery sign-in for account \(account.id!)")
        return try jsonResponse(RecoverySessionResponse(token: token, account: account.dto,
                                                        device: device.dto(currentDeviceID: device.id),
                                                        wrappedByRecovery: account.wrappedByRecovery))
    }

    func signOut(_ context: SyncRequestContext) async throws -> Response {
        try await context.requireAuth().device.delete(on: db)
        return Response(status: .noContent)
    }

    func changePassword(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let auth = try context.requireAuth()
        let account = auth.account
        let body = try await request.decode(as: PasswordChangeRequest.self, context: context)
        let verified: Bool
        switch (body.authKey, body.recoveryAuthKey) {
        case let (authKey?, nil):
            verified = Security.verifyKey(authKey, salt: account.keySalt, hash: account.authKeyHash)
        case let (nil, recoveryAuthKey?):
            verified = Security.verifyKey(recoveryAuthKey, salt: account.keySalt, hash: account.recoveryAuthKeyHash)
        default:
            throw APIError.badRequest("Send exactly one of authKey and recoveryAuthKey.")
        }
        try validateAuthKey(body.newAuthKey, "newAuthKey")
        try validateKDF(body.newKdf)
        try validateWrappedKey(body.newWrappedByPassword, "newWrappedByPassword")
        guard verified else { throw APIError.invalidCredentials() }

        account.authKeyHash = Security.hashKey(body.newAuthKey, salt: account.keySalt)
        account.kdf = body.newKdf
        account.wrappedByPassword = body.newWrappedByPassword
        let device = auth.device
        try await db.transaction { db in
            try await account.save(on: db)
            if device.scope != Device.Scope.full.rawValue {
                device.scope = Device.Scope.full.rawValue
                try await device.save(on: db)
            }
        }
        context.logger.info("Password changed for account \(account.id!)")
        return try jsonResponse(account.dto)
    }

    func rotateRecovery(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let account = try context.requireAuth().account
        let body = try await request.decode(as: RecoveryRotateRequest.self, context: context)
        try validateAuthKey(body.newRecoveryAuthKey, "newRecoveryAuthKey")
        try validateWrappedKey(body.newWrappedByRecovery, "newWrappedByRecovery")
        guard Security.verifyKey(body.authKey, salt: account.keySalt, hash: account.authKeyHash) else {
            throw APIError.invalidCredentials()
        }
        account.recoveryAuthKeyHash = Security.hashKey(body.newRecoveryAuthKey, salt: account.keySalt)
        account.wrappedByRecovery = body.newWrappedByRecovery
        account.recoveryUpdatedAt = Security.now()
        try await account.save(on: db)
        return try jsonResponse(account.dto)
    }

    func deleteAccount(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let account = try context.requireAuth().account
        let body = try await request.decode(as: DeleteAccountRequest.self, context: context)
        guard Security.verifyKey(body.authKey, salt: account.keySalt, hash: account.authKeyHash) else {
            throw APIError.invalidCredentials()
        }
        let accountID = try account.requireID()
        try await db.transaction { db in
            try await Vault.query(on: db).filter(\.$accountID == accountID).delete()
            try await Device.query(on: db).filter(\.$accountID == accountID).delete()
            try await account.delete(on: db)
        }
        context.logger.info("Deleted account \(accountID)")
        return Response(status: .noContent)
    }

    // MARK: Vault

    func vault(_ context: SyncRequestContext) async throws -> Response {
        try jsonResponse(try await currentVault(context).dto)
    }

    func vaultHead(_ context: SyncRequestContext) async throws -> Response {
        try jsonResponse(try await currentVault(context).head)
    }

    /// `PUT /v1/vault` with `If-Match: <revision>`: compare-and-swap on the revision.
    func putVault(_ request: Request, _ context: SyncRequestContext) async throws -> Response {
        let auth = try context.requireAuth()
        guard let ifMatch = request.headers[.ifMatch] else {
            throw APIError(status: .preconditionRequired, code: ErrorDTO.Code.preconditionRequired,
                           message: "Send If-Match with the revision this upload is based on (0 for the first).")
        }
        guard let expected = Self.parseRevision(ifMatch) else {
            throw APIError.badRequest("If-Match must be a revision number.")
        }
        let buffer = try await request.body.collect(upTo: APILimits.maxVaultBodyBytes)
        let body: VaultPutRequest
        do {
            body = try SyncCoding.decoder.decode(VaultPutRequest.self, from: Data(buffer.readableBytesView))
        } catch {
            throw APIError.badRequest("The body must be {\"ciphertext\": \"<base64>\"}.")
        }
        guard !body.ciphertext.isEmpty else { throw APIError.badRequest("The ciphertext is empty.") }

        let accountID = try auth.account.requireID()
        let deviceID = try auth.device.requireID()
        let now = Security.now()

        if expected == 0 {
            if let existing = try await Vault.query(on: db).filter(\.$accountID == accountID).first() {
                throw try APIError.staleRevision(existing.head)
            }
            let vault = Vault()
            vault.accountID = accountID
            vault.revision = 1
            vault.modifiedAt = now
            vault.deviceID = deviceID
            vault.ciphertext = body.ciphertext
            do {
                try await vault.create(on: db)
            } catch let error as any DatabaseError where error.isConstraintFailure {
                // Another device created it first.
                try await throwStale(accountID)
            }
            return try jsonResponse(VaultPutResponse(revision: 1, modifiedAt: now))
        }

        guard let sql = db as? any SQLDatabase else { throw APIError.badRequest("Unsupported database.") }
        let updated = try await sql.update(Vault.schema)
            .set("revision", to: expected + 1)
            .set("modified_at", to: now)
            .set("device_id", to: deviceID)
            .set("ciphertext", to: body.ciphertext)
            .where("account_id", .equal, accountID)
            .where("revision", .equal, expected)
            .returning("revision")
            .all()
        guard !updated.isEmpty else { try await throwStale(accountID) }
        return try jsonResponse(VaultPutResponse(revision: expected + 1, modifiedAt: now))
    }

    /// Accepts `3`, `"3"` and `W/"3"`.
    static func parseRevision(_ header: String) -> Int? {
        var value = header.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("W/") { value.removeFirst(2) }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
        guard let revision = Int(value), revision >= 0 else { return nil }
        return revision
    }

    private func throwStale(_ accountID: UUID) async throws -> Never {
        if let current = try await Vault.query(on: db).filter(\.$accountID == accountID).first() {
            throw try APIError.staleRevision(current.head)
        }
        throw APIError(status: .conflict, code: ErrorDTO.Code.conflict,
                       message: "There is no vault yet; upload with If-Match: 0.")
    }

    private func currentVault(_ context: SyncRequestContext) async throws -> Vault {
        let accountID = try context.requireAuth().account.requireID()
        guard let vault = try await Vault.query(on: db).filter(\.$accountID == accountID).first() else {
            throw APIError.notFound("There is no vault yet.")
        }
        return vault
    }

    // MARK: Devices

    func devices(_ context: SyncRequestContext) async throws -> Response {
        let auth = try context.requireAuth()
        let devices = try await Device.query(on: db)
            .filter(\.$accountID == auth.account.requireID())
            .sort(\.$createdAt, .ascending)
            .sort(\.$id, .ascending)
            .all()
        return try jsonResponse(devices.map { $0.dto(currentDeviceID: auth.device.id) })
    }

    func deleteDevice(_ context: SyncRequestContext) async throws -> Response {
        let auth = try context.requireAuth()
        guard let id = context.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
            throw APIError.badRequest("The device id must be a UUID.")
        }
        guard let device = try await Device.query(on: db)
            .filter(\.$id == id)
            .filter(\.$accountID == auth.account.requireID())
            .first()
        else {
            throw APIError.notFound("No such device.")
        }
        try await device.delete(on: db)
        return Response(status: .noContent)
    }

    // MARK: Helpers

    /// The account for `email` if `verify` accepts it; 401 otherwise. Unknown emails still
    /// hash a key so both failures take about as long.
    private func verifiedAccount(email rawEmail: String, verify: (Account) -> Bool) async throws -> Account {
        guard let email = Security.normalizeEmail(rawEmail),
              let account = try await Account.query(on: db).filter(\.$email == email).first()
        else {
            _ = Security.verifyKey(Data(count: Security.authKeyByteCount), salt: Data(count: Security.saltByteCount),
                                   hash: Data(count: 32))
            throw APIError.invalidCredentials()
        }
        guard verify(account) else { throw APIError.invalidCredentials() }
        return account
    }

    private func makeDevice(_ info: DeviceInfo, scope: Device.Scope, now: Date) -> (Device, String) {
        let (token, hash) = Security.newToken()
        let device = Device()
        device.id = UUID()
        device.name = info.name
        device.model = info.model
        device.os = info.os
        device.tokenHash = hash
        device.scope = scope.rawValue
        device.createdAt = now
        device.lastSeenAt = now
        return (device, token)
    }

    private func validateAuthKey(_ key: Data, _ name: String) throws {
        guard key.count == Security.authKeyByteCount else {
            throw APIError.badRequest("\(name) must be \(Security.authKeyByteCount) bytes.")
        }
    }

    private func validateWrappedKey(_ wrapped: Data, _ name: String) throws {
        guard (28...1024).contains(wrapped.count) else {
            throw APIError.badRequest("\(name) must be an AES-GCM sealed key.")
        }
    }

    private func validateKDF(_ kdf: KDFParams) throws {
        guard kdf.isSupported, kdf.salt.count <= 64 else {
            throw APIError.badRequest("Unsupported key-derivation parameters.")
        }
        guard kdf.n >= minimumScryptN, kdf.r >= KDFParams.minimumR else {
            throw APIError.badRequest("The key-derivation parameters are too weak.")
        }
    }

    private func validateDevice(_ device: DeviceInfo) throws {
        guard [device.name, device.model, device.os].allSatisfy({ $0.count <= 200 }) else {
            throw APIError.badRequest("Device fields are limited to 200 characters.")
        }
    }
}
