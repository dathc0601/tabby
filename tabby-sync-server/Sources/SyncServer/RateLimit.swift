import Foundation
import HTTPTypes
import Hummingbird

/// Fixed-window request counter per key, in memory (one server process).
actor RateLimiter {
    let limit: Int
    let window: TimeInterval
    private var buckets: [String: (start: Date, count: Int)] = [:]

    init(limit: Int, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    /// Counts a request; returns nil when allowed, or the seconds until the window resets.
    func hit(_ key: String, now: Date = Date()) -> Int? {
        if buckets.count > 10_000 {
            buckets = buckets.filter { now.timeIntervalSince($0.value.start) < window }
        }
        var bucket = buckets[key] ?? (now, 0)
        if now.timeIntervalSince(bucket.start) >= window {
            bucket = (now, 0)
        }
        bucket.count += 1
        buckets[key] = bucket
        guard bucket.count > limit else { return nil }
        return max(1, Int((window - now.timeIntervalSince(bucket.start)).rounded(.up)))
    }
}

/// Limits a route group per client address and route (`POST /v1/session` from one address
/// does not use up `POST /v1/account`).
struct RateLimitMiddleware: RouterMiddleware {
    typealias Context = SyncRequestContext
    let limiter: RateLimiter

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let key = "\(request.method) \(request.uri.path) \(clientAddress(request, context))"
        if let retryAfter = await limiter.hit(key) {
            context.logger.notice("Rate limited \(key)")
            throw APIError.rateLimited(retryAfter: retryAfter)
        }
        return try await next(request, context)
    }
}

extension HTTPField.Name {
    static let xForwardedFor = HTTPField.Name("X-Forwarded-For")!
}

/// The client's address: the first `X-Forwarded-For` entry (set by the reverse proxy, which
/// must overwrite what clients send), else the socket peer.
func clientAddress(_ request: Request, _ context: SyncRequestContext) -> String {
    if let forwarded = request.headers[.xForwardedFor],
       let first = forwarded.split(separator: ",").first?.trimmingCharacters(in: .whitespaces), !first.isEmpty {
        return first
    }
    return context.peerAddress ?? "unknown"
}
