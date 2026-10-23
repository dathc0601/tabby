#if os(macOS)
import Foundation

// Socket helpers shared by the SSH, telnet and app integration tests. Everything listens on
// 127.0.0.1 on a port the kernel picks, so no test ever collides with a real service.

/// A port nothing listens on right now (the kernel's pick for an ephemeral bind).
public func freeTCPPort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard bound else { throw NSError(domain: "freeTCPPort", code: 2) }
    return Int(UInt16(bigEndian: address.sin_port))
}

/// A listening socket on 127.0.0.1 with a kernel-chosen port.
func listeningSocket(backlog: Int32 = 8) throws -> (fd: Int32, port: Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
        }
    }
    guard ok, listen(fd, backlog) == 0 else {
        close(fd)
        throw NSError(domain: "listeningSocket", code: 1)
    }
    return (fd, Int(UInt16(bigEndian: address.sin_port)))
}

/// A TCP echo server on 127.0.0.1 (a forward's target, a raw-socket peer).
public final class EchoServer: @unchecked Sendable {
    public let port: Int
    private let listener: Int32

    public init() throws {
        let (fd, port) = try listeningSocket()
        listener = fd
        self.port = port
        // Closing the listener in stop() makes accept fail, which ends this thread.
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                Thread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(client, &buffer, buffer.count)
                        if n <= 0 { break }
                        _ = write(client, buffer, n)
                    }
                    close(client)
                }.start()
            }
        }.start()
    }

    public func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    deinit { stop() }
}

/// Writes `text` to `fd` and reads until as many bytes came back (or 5 s pass).
public func roundTrip(_ fd: Int32, _ text: String) -> String {
    let bytes = Array(text.utf8)
    _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    var received = [UInt8]()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let deadline = Date().addingTimeInterval(5)
    while received.count < bytes.count, Date() < deadline {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 100) > 0 else { continue }
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        received += buffer[0..<n]
    }
    return String(decoding: received, as: UTF8.self)
}

/// Reads until EOF (or `timeout`).
public func readAll(_ fd: Int32, timeout: TimeInterval = 20) -> Data {
    var received = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, 100) > 0 else { continue }
        let n = read(fd, &buffer, buffer.count)
        if n <= 0 { break }
        received.append(contentsOf: buffer[0..<n])
    }
    return received
}
/// A one-client TCP server on 127.0.0.1 driven by the test: it records what the client sends
/// and sends what the test tells it to (a telnet server whose every byte the test chooses).
public final class ScriptedTCPServer: @unchecked Sendable {
    public let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var bytes = Data()
    private var clientClosed = false

    public init() throws {
        let (fd, port) = try listeningSocket(backlog: 1)
        listener = fd
        self.port = port
        Thread { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            guard let self else { close(client); return }
            self.lock.withLock { self.client = client }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                self.lock.withLock { self.bytes.append(contentsOf: buffer[0..<n]) }
            }
            self.lock.withLock { self.clientClosed = true }
        }.start()
    }

    public var hasClient: Bool { lock.withLock { client >= 0 } }
    /// Everything the client has sent so far.
    public var received: Data { lock.withLock { bytes } }
    /// The client closed its end.
    public var clientHasClosed: Bool { lock.withLock { clientClosed } }

    public func send(_ data: Data) {
        let fd = lock.withLock { client }
        guard fd >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    public func send(_ text: String) { send(Data(text.utf8)) }

    /// Closes the connection from the server's side.
    public func closeClient() {
        let fd = lock.withLock { () -> Int32 in
            defer { client = -1 }
            return client
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    public func stop() {
        closeClient()
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    deinit { stop() }
}

/// Runs the main run loop until `condition` holds or `timeout` passes; sessions deliver
/// their callbacks on the main queue.
@discardableResult
public func spinMainLoop(timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

extension Data {
    /// Whether `other` appears in this data as a contiguous run.
    public func contains(_ other: Data) -> Bool { range(of: other) != nil }
}
#endif
