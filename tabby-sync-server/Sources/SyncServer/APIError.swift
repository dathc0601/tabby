import Foundation
import HTTPTypes
import Hummingbird
import TabbySyncProtocol

/// An error answered as JSON: an `ErrorDTO`, or a custom body (the `VaultHead` of a 409).
struct APIError: HTTPResponseError {
    let status: HTTPResponse.Status
    let code: String
    let message: String
    var headers: HTTPFields = [:]
    /// Replaces the `ErrorDTO` body when set.
    var body: Data?

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let data = try body ?? SyncCoding.encoder.encode(ErrorDTO(error: code, message: message))
        var response = jsonResponse(data, status: status)
        response.headers.append(contentsOf: headers)
        return response
    }

    static func badRequest(_ message: String) -> APIError {
        APIError(status: .badRequest, code: ErrorDTO.Code.badRequest, message: message)
    }

    static func invalidEmail() -> APIError {
        APIError(status: .badRequest, code: ErrorDTO.Code.invalidEmail, message: "That is not an email address.")
    }

    static func unauthorized() -> APIError {
        APIError(status: .unauthorized, code: ErrorDTO.Code.unauthorized,
                 message: "Sign in again: the token is missing, invalid or revoked.",
                 headers: [.wwwAuthenticate: "Bearer"])
    }

    static func invalidCredentials() -> APIError {
        APIError(status: .unauthorized, code: ErrorDTO.Code.invalidCredentials, message: "Wrong email, password or key.")
    }

    static func forbidden() -> APIError {
        APIError(status: .forbidden, code: ErrorDTO.Code.forbidden,
                 message: "Set a new password before using this session for anything else.")
    }

    static func notFound(_ message: String) -> APIError {
        APIError(status: .notFound, code: ErrorDTO.Code.notFound, message: message)
    }

    static func emailTaken() -> APIError {
        APIError(status: .conflict, code: ErrorDTO.Code.emailTaken, message: "An account with that email exists.")
    }

    /// 409 for a stale `If-Match`, with the current head so the client can merge.
    static func staleRevision(_ head: VaultHead) throws -> APIError {
        APIError(status: .conflict, code: ErrorDTO.Code.conflict, message: "Revision \(head.revision) is current.",
                 body: try SyncCoding.encoder.encode(head))
    }

    static func rateLimited(retryAfter seconds: Int) -> APIError {
        APIError(status: .tooManyRequests, code: ErrorDTO.Code.rateLimited, message: "Too many attempts; try again later.",
                 headers: [.retryAfter: String(seconds)])
    }
}

func jsonResponse(_ data: Data, status: HTTPResponse.Status = .ok) -> Response {
    Response(
        status: status,
        headers: [.contentType: "application/json; charset=utf-8", .contentLength: String(data.count)],
        body: .init(byteBuffer: ByteBuffer(bytes: data))
    )
}

func jsonResponse(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
    jsonResponse(try SyncCoding.encoder.encode(value), status: status)
}

/// Answers every error as JSON: `APIError`s as they are, other HTTP errors (bad JSON, body
/// too large) with the matching `ErrorDTO` code, anything else as a logged 500.
struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as APIError {
            throw error
        } catch let error as any HTTPResponseError {
            let message = (error as? HTTPError)?.body ?? error.status.reasonPhrase
            throw APIError(status: error.status, code: Self.code(for: error.status), message: message)
        } catch {
            context.logger.error("Unhandled error on \(request.method) \(request.uri.path): \(String(reflecting: error))")
            throw APIError(status: .internalServerError, code: ErrorDTO.Code.internalError, message: "Internal server error.")
        }
    }

    static func code(for status: HTTPResponse.Status) -> String {
        switch status.code {
        case 400: ErrorDTO.Code.badRequest
        case 401: ErrorDTO.Code.unauthorized
        case 403: ErrorDTO.Code.forbidden
        case 404: ErrorDTO.Code.notFound
        case 409: ErrorDTO.Code.conflict
        case 413: ErrorDTO.Code.payloadTooLarge
        case 428: ErrorDTO.Code.preconditionRequired
        case 429: ErrorDTO.Code.rateLimited
        case 400..<500: ErrorDTO.Code.badRequest
        default: ErrorDTO.Code.internalError
        }
    }
}
