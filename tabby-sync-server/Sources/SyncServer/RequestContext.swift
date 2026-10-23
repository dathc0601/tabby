import Foundation
import Hummingbird
import TabbySyncProtocol

/// Per-request state: JSON through `SyncCoding`, a 64 KB body limit for decoded requests
/// (`PUT /v1/vault` collects its body itself, up to 25 MB), the peer address for rate
/// limiting, and the signed-in device once `AuthMiddleware` has run.
struct SyncRequestContext: RequestContext {
    var coreContext: CoreRequestContextStorage
    /// The socket peer (the reverse proxy in production; see `clientAddress`).
    let peerAddress: String?
    var auth: Auth?

    init(source: ApplicationRequestContextSource) {
        self.coreContext = .init(source: source)
        self.peerAddress = source.channel.remoteAddress?.ipAddress
    }

    var maxUploadSize: Int { APILimits.maxBodyBytes }
    var requestDecoder: JSONDecoder { SyncCoding.decoder }
    var responseEncoder: JSONEncoder { SyncCoding.encoder }

    func requireAuth() throws -> Auth {
        guard let auth else { throw APIError.unauthorized() }
        return auth
    }
}

/// The account and device a bearer token belongs to.
struct Auth: Sendable {
    let account: Account
    let device: Device
}
