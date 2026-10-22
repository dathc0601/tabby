import FluentKit
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdFluent

/// Resolves `Authorization: Bearer <token>` to its device and account (401 otherwise),
/// records `lastSeenAt`, and refuses recovery-scoped tokens (403) unless the group allows
/// them.
struct AuthMiddleware: RouterMiddleware {
    typealias Context = SyncRequestContext
    let fluent: Fluent
    let allowRecoveryScope: Bool

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization] else { throw APIError.unauthorized() }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { throw APIError.unauthorized() }
        let token = parts[1].trimmingCharacters(in: .whitespaces)

        let db = fluent.db()
        guard let device = try await Device.query(on: db).filter(\.$tokenHash == Security.tokenHash(token)).first(),
              let account = try await Account.find(device.accountID, on: db)
        else {
            throw APIError.unauthorized()
        }
        if device.scope == Device.Scope.recovery.rawValue, !allowRecoveryScope {
            throw APIError.forbidden()
        }
        device.lastSeenAt = Security.now()
        try await device.save(on: db)

        var context = context
        context.auth = Auth(account: account, device: device)
        return try await next(request, context)
    }
}
