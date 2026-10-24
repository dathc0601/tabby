#if os(macOS)
import Foundation
import TabbyCore

/// Opens a tunnel through a SOCKS5 or HTTP CONNECT proxy and returns its socket, ready for
/// SSH. Replies are read a byte at a time so nothing of the server's banner is taken.
enum ProxyTunnel {
    static func open(_ proxy: SSHProxy, to host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        let (proxyHost, proxyPort) = switch proxy {
        case let .socks5(h, p): (h, p)
        case let .http(h, p): (h, p)
        }
        let fd = try connect(host: proxyHost, port: proxyPort, timeout: timeout)
        do {
            switch proxy {
            case .socks5:
                try send(fd, SOCKS5.clientGreeting)
                _ = try readUntilDone(fd, timeout: timeout, SOCKS5.parseServerChoice)
                try send(fd, SOCKS5.connectRequest(host: host, port: port))
                _ = try readUntilDone(fd, timeout: timeout, SOCKS5.parseConnectReply)
            case .http:
                try send(fd, Array(HTTPConnect.request(host: host, port: port).utf8))
                _ = try readUntilDone(fd, timeout: timeout, HTTPConnect.parseResponse)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func fail(_ text: String) -> SSHConnectionError { .connectFailed(L("Proxy: {text}", ["text": text])) }

    /// A blocking TCP socket connected within `timeout` (non-blocking connect + poll: macOS
    /// ignores send timeouts for connect()).
    static func connect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let first = list else {
            throw fail(L("cannot resolve {host}", ["host": host]))
        }
        defer { freeaddrinfo(list) }
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = L("connection refused")
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            current = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var connected = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0
            if !connected, errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let wait = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                if poll(&pfd, 1, wait) > 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                    connected = error == 0
                    if error != 0 { errno = error }
                } else {
                    errno = ETIMEDOUT
                }
            }
            if connected {
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                return fd
            }
            lastError = String(cString: strerror(errno))
            close(fd)
        }
        throw fail(L("could not connect to {host}:{port} ({lastError})", ["host": host, "port": port, "lastError": lastError]))
    }

    private static func send(_ fd: Int32, _ bytes: [UInt8]) throws {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            guard n > 0 else { throw fail(L("the proxy closed the connection")) }
            offset += n
        }
    }

    private static func readUntilDone<T>(_ fd: Int32, timeout: TimeInterval, _ parse: ([UInt8]) -> HandshakeStep<T>) throws -> T {
        var data = [UInt8]()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch parse(data) {
            case let .done(value, _): return value
            case let .failure(text): throw fail(text)
            case .needMore: break
            }
            guard data.count < 16_384 else { throw fail(L("no answer from the proxy")) }
            // Wait no longer than the deadline for each byte.
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let wait = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
            guard wait > 0, poll(&pfd, 1, wait) > 0 else { throw fail(L("no answer from the proxy")) }
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { throw fail(L("the proxy closed the connection")) }
            data.append(byte)
        }
    }
}
#endif
