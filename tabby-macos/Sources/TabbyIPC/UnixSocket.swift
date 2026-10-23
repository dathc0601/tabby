import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal blocking Unix-domain stream sockets carrying newline-delimited JSON.
/// Shared by the app (server) and the `tabby-askpass` helper (client).
public enum UnixSocket {
    public struct SocketError: Error, CustomStringConvertible {
        public var description: String
        init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
    }

    static var streamType: Int32 {
        #if canImport(Darwin)
        return SOCK_STREAM
        #else
        return Int32(SOCK_STREAM.rawValue)
        #endif
    }

    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            throw SocketError("Socket path too long (\(bytes.count) bytes)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Creates a listening socket at `path` (replacing a stale one), mode 0600.
    public static func listen(path: String) throws -> Int32 {
        unlink(path)
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        let r = try withAddress(path) { bind(fd, $0, $1) }
        guard r == 0 else { close(fd); throw SocketError("bind \(path)") }
        chmod(path, 0o600)
        guard Glibc_listen(fd, 16) == 0 else { close(fd); throw SocketError("listen") }
        return fd
    }

    public static func connect(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, streamType, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        let r = try withAddress(path) { sysConnect(fd, $0, $1) }
        guard r == 0 else { close(fd); throw SocketError("connect \(path)") }
        return fd
    }

    public static func accept(_ listener: Int32) -> Int32 {
        var r: Int32
        repeat { r = sysAccept(listener, nil, nil) } while r < 0 && errno == EINTR
        return r
    }

    /// Reads one line (without the newline). Returns nil on EOF before any newline.
    public static func readLine(_ fd: Int32, limit: Int = 1 << 20) -> String? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < limit {
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == 0x0a { return String(decoding: data, as: UTF8.self) }
                data.append(byte)
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                return data.isEmpty ? nil : String(decoding: data, as: UTF8.self)
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func writeLine(_ fd: Int32, _ line: String) {
        let data = Array((line + "\n").utf8)
        var offset = 0
        while offset < data.count {
            let n = data[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue } else { return } }
            offset += n
        }
    }

    public static func closeSocket(_ fd: Int32) {
        close(fd)
    }
}

// Free functions so the static members above don't shadow libc names.
private func Glibc_listen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func sysConnect(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ len: socklen_t) -> Int32 { connect(fd, addr, len) }
private func sysAccept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>?, _ len: UnsafeMutablePointer<socklen_t>?) -> Int32 { accept(fd, addr, len) }

/// Messages exchanged between `tabby-askpass` and the app.
public struct AskpassRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// ssh is asking for input (argv[1] is the prompt).
        case prompt
        /// ssh ran `LocalCommand`: authentication succeeded.
        case connected
    }

    public var kind: Kind
    public var session: String
    public var token: String
    public var prompt: String
    /// `SSH_ASKPASS_PROMPT`: `confirm`, `none`, or empty for secret input.
    public var promptType: String?

    public init(kind: Kind, session: String, token: String, prompt: String = "", promptType: String? = nil) {
        self.kind = kind
        self.session = session
        self.token = token
        self.prompt = prompt
        self.promptType = promptType
    }
}

public struct AskpassResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var answer: String?

    public init(ok: Bool, answer: String? = nil) {
        self.ok = ok
        self.answer = answer
    }
}

/// Environment variables shared by the app and the helper.
public enum AskpassEnvironment {
    public static let socketKey = "TABBYMAC_ASKPASS_SOCKET"
    public static let sessionKey = "TABBYMAC_SESSION"
    public static let tokenKey = "TABBYMAC_SESSION_TOKEN"
}
