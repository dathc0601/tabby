import Foundation

extension ForwardedPort {
    /// Tabby's label for a forward (`ForwardedPort.toString`).
    public var summary: String {
        switch type {
        case .local: return "(local) \(host):\(port) → (remote) \(targetAddress):\(targetPort)"
        case .remote: return "(remote) \(host):\(port) → (local) \(targetAddress):\(targetPort)"
        case .dynamic: return "(dynamic) \(host):\(port)"
        }
    }
}

/// Incremental parse result for the proxy handshakes.
public enum HandshakeStep<Value: Equatable>: Equatable {
    case needMore
    case done(Value, consumed: Int)
    case failure(String)
}

/// SOCKS5 (RFC 1928), no authentication, CONNECT only: the server side runs dynamic
/// forwards, the client side reaches hosts through `socksProxyHost`.
public enum SOCKS5 {
    public struct Target: Equatable, Sendable {
        public var host: String
        public var port: Int
        public init(host: String, port: Int) {
            self.host = host
            self.port = port
        }
    }

    public enum ReplyCode: UInt8 {
        case succeeded = 0, generalFailure = 1, notAllowed = 2, networkUnreachable = 3, hostUnreachable = 4,
             connectionRefused = 5, ttlExpired = 6, commandNotSupported = 7, addressTypeNotSupported = 8

        var reason: String {
            switch self {
            case .succeeded: return "succeeded"
            case .generalFailure: return "general failure"
            case .notAllowed: return "not allowed by the proxy"
            case .networkUnreachable: return "network unreachable"
            case .hostUnreachable: return "host unreachable"
            case .connectionRefused: return "connection refused"
            case .ttlExpired: return "TTL expired"
            case .commandNotSupported: return "command not supported"
            case .addressTypeNotSupported: return "address type not supported"
            }
        }
    }

    public static let noAuthAccepted: [UInt8] = [5, 0]
    public static let noAcceptableMethod: [UInt8] = [5, 0xFF]
    public static let clientGreeting: [UInt8] = [5, 1, 0]

    // MARK: Server

    /// The client's greeting; the value is the answer to send.
    public static func parseGreeting(_ data: [UInt8]) -> HandshakeStep<[UInt8]> {
        guard data.count >= 2 else { return .needMore }
        guard data[0] == 5 else { return .failure("not SOCKS5") }
        let count = Int(data[1])
        guard data.count >= 2 + count else { return .needMore }
        let methods = data[2..<(2 + count)]
        return .done(methods.contains(0) ? noAuthAccepted : noAcceptableMethod, consumed: 2 + count)
    }

    /// A CONNECT request's target.
    public static func parseConnect(_ data: [UInt8]) -> HandshakeStep<Target> {
        guard data.count >= 4 else { return .needMore }
        guard data[0] == 5 else { return .failure("not SOCKS5") }
        guard data[1] == 1 else { return .failure("only CONNECT is supported") }
        guard let (host, length) = address(data, at: 3) else {
            return data[3] == 1 || data[3] == 3 || data[3] == 4 ? .needMore : .failure("unknown address type")
        }
        let end = 3 + length
        guard data.count >= end + 2 else { return .needMore }
        return .done(Target(host: host, port: Int(data[end]) << 8 | Int(data[end + 1])), consumed: end + 2)
    }

    /// The server's answer to CONNECT (bound address 0.0.0.0:0).
    public static func reply(_ code: ReplyCode) -> [UInt8] {
        [5, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0]
    }

    // MARK: Client

    /// CONNECT by name, so the proxy resolves it (like ssh's `nc -X 5`).
    public static func connectRequest(host: String, port: Int) -> [UInt8] {
        let name = Array(host.utf8.prefix(255))
        return [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8 & 0xFF), UInt8(port & 0xFF)]
    }

    public static func parseServerChoice(_ data: [UInt8]) -> HandshakeStep<UInt8> {
        guard data.count >= 2 else { return .needMore }
        guard data[0] == 5 else { return .failure("the SOCKS proxy does not speak SOCKS5") }
        guard data[1] == 0 else { return .failure("the SOCKS proxy wants authentication") }
        return .done(0, consumed: 2)
    }

    public static func parseConnectReply(_ data: [UInt8]) -> HandshakeStep<UInt8> {
        guard data.count >= 4 else { return .needMore }
        guard data[0] == 5 else { return .failure("the SOCKS proxy does not speak SOCKS5") }
        guard data[1] == 0 else {
            let reason = ReplyCode(rawValue: data[1])?.reason ?? "error \(data[1])"
            return .failure("the SOCKS proxy could not connect (\(reason))")
        }
        guard let (_, length) = address(data, at: 3) else {
            return data[3] == 1 || data[3] == 3 || data[3] == 4 ? .needMore : .failure("the SOCKS proxy sent an unknown address type")
        }
        let end = 3 + length + 2
        guard data.count >= end else { return .needMore }
        return .done(0, consumed: end)
    }

    /// The address at `index` (type byte included) and its length, or nil when incomplete.
    private static func address(_ data: [UInt8], at index: Int) -> (String, Int)? {
        switch data[index] {
        case 1:
            guard data.count >= index + 5 else { return nil }
            return (data[(index + 1)..<(index + 5)].map(String.init).joined(separator: "."), 5)
        case 3:
            guard data.count >= index + 2 else { return nil }
            let length = Int(data[index + 1])
            guard data.count >= index + 2 + length else { return nil }
            return (String(decoding: data[(index + 2)..<(index + 2 + length)], as: UTF8.self), 2 + length)
        case 4:
            guard data.count >= index + 17 else { return nil }
            let bytes = Array(data[(index + 1)..<(index + 17)])
            return (ipv6String(bytes), 17)
        default:
            return nil
        }
    }

    /// RFC 5952 text form (longest run of zero groups as `::`).
    static func ipv6String(_ bytes: [UInt8]) -> String {
        let groups = stride(from: 0, to: 16, by: 2).map { Int(bytes[$0]) << 8 | Int(bytes[$0 + 1]) }
        var best = (start: -1, length: 0)
        var index = 0
        while index < 8 {
            guard groups[index] == 0 else { index += 1; continue }
            var end = index
            while end < 8, groups[end] == 0 { end += 1 }
            if end - index > best.length, end - index > 1 { best = (index, end - index) }
            index = end
        }
        let hex = groups.map { String($0, radix: 16) }
        guard best.start >= 0 else { return hex.joined(separator: ":") }
        let head = hex[..<best.start].joined(separator: ":")
        let tail = hex[(best.start + best.length)...].joined(separator: ":")
        return head + "::" + tail
    }
}

/// HTTP CONNECT tunnelling through `httpProxyHost`.
public enum HTTPConnect {
    public static func request(host: String, port: Int) -> String {
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        return "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n\r\n"
    }

    /// The status once the whole header has arrived; bytes after it belong to SSH.
    public static func parseResponse(_ data: [UInt8]) -> HandshakeStep<Int> {
        let terminator: [UInt8] = [13, 10, 13, 10]
        guard data.count >= 4, let end = (0...(data.count - 4)).first(where: { Array(data[$0..<($0 + 4)]) == terminator }) else {
            return .needMore
        }
        let header = String(decoding: data[..<end], as: UTF8.self)
        let statusLine = header.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else {
            return .failure("the HTTP proxy sent something unexpected")
        }
        guard (200..<300).contains(status) else {
            return .failure("the HTTP proxy answered \(parts.dropFirst().joined(separator: " "))")
        }
        return .done(status, consumed: end + 4)
    }
}

/// Where X11 connections from the server go (Tabby's `X11Socket.resolveDisplaySpec`):
/// `[host]:N[.S]` is TCP port 6000 + N (displays from 100 are ports), `unix` or no host is
/// `/tmp/.X11-unix/XN`, and a display starting with `/` is a socket path (XQuartz's).
public enum X11Display: Equatable, Sendable {
    case tcp(host: String, port: Int)
    case socket(path: String)

    public static func resolve(_ setting: String?, environment display: String?) -> X11Display {
        let spec = setting.flatMap { $0.isEmpty ? nil : $0 } ?? display.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost:0"
        if spec.hasPrefix("/") { return .socket(path: spec) }
        var host: String?
        var number = 0
        if let colon = spec.lastIndex(of: ":") {
            let name = String(spec[..<colon])
            let rest = spec[spec.index(after: colon)...]
            let digits = rest.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
            if let n = Int(digits), !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                number = n
                host = name.isEmpty ? nil : name
            }
        }
        let resolvedHost = host ?? "unix"
        if resolvedHost == "unix" { return .socket(path: "/tmp/.X11-unix/X\(number)") }
        return .tcp(host: resolvedHost, port: number < 100 ? number + 6000 : number)
    }
}
