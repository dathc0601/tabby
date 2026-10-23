#if os(macOS)
import Foundation
import XCTest
import TabbyTestSupport

/// A throwaway sshd for the library backend's integration tests: the system's
/// `/usr/sbin/sshd`, unprivileged, on a free 127.0.0.1 port, with its own host key and an
/// authorized test key in a temp folder. It logs in as the current user only, by public key.
/// Nothing reads or writes the real `~/.ssh`.
final class TestSSHD {
    let directory: URL
    let port: Int
    let user = NSUserName()
    /// The authorized test key (unencrypted) and one protected by `passphrase`.
    let keyPath: String
    let encryptedKeyPath: String
    let passphrase = "correct horse"
    let hostKeyPath: String
    private let process = Process()

    init(name: String = "sshd", extraConfig: String = "") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabby-\(name)-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hostKeyPath = directory.appendingPathComponent("host_ed25519").path
        keyPath = directory.appendingPathComponent("user_ed25519").path
        encryptedKeyPath = directory.appendingPathComponent("user_encrypted").path
        try Self.keygen(hostKeyPath, passphrase: "")
        try Self.keygen(keyPath, passphrase: "")
        try Self.keygen(encryptedKeyPath, passphrase: passphrase)
        let authorized = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            + String(contentsOfFile: encryptedKeyPath + ".pub", encoding: .utf8)
        let authorizedPath = directory.appendingPathComponent("authorized_keys").path
        try authorized.write(toFile: authorizedPath, atomically: true, encoding: .utf8)
        port = try Self.freePort()
        let config = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(hostKeyPath)
        PidFile \(directory.path)/sshd.pid
        AuthorizedKeysFile \(authorizedPath)
        StrictModes no
        UsePAM no
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PubkeyAuthentication yes
        AllowTcpForwarding yes
        AllowAgentForwarding yes
        GatewayPorts no
        Subsystem sftp /usr/libexec/sftp-server
        LogLevel ERROR
        \(extraConfig)
        """
        let configPath = directory.appendingPathComponent("sshd_config").path
        try config.write(toFile: configPath, atomically: true, encoding: .utf8)
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-D", "-e", "-f", configPath]
        // Not the test runner's pipes: an sshd left over by a crashed test would keep them open
        // and swift test would wait forever.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try waitUntilListening()
    }

    /// The host key's SHA256 fingerprint as ssh-keygen prints it (`SHA256:…`).
    var hostKeyFingerprint: String {
        let out = Self.run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", hostKeyPath + ".pub"])
        return out.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    func stop() {
        Self.end(process)
        try? FileManager.default.removeItem(at: directory)
    }

    /// Terminates and waits by polling: `waitUntilExit()` needs a run loop and can hang on a
    /// Swift concurrency thread (async tearDown).
    static func end(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    deinit { stop() }

    // MARK: Helpers

    static func keygen(_ path: String, passphrase: String) throws {
        let out = run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", passphrase, "-C", "tabby-test", "-f", path])
        guard FileManager.default.fileExists(atPath: path) else { throw NSError(domain: "TestSSHD", code: 1, userInfo: [NSLocalizedDescriptionKey: out]) }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning, Date() < deadline { usleep(5_000) }
        return String(decoding: data, as: UTF8.self)
    }

    static func freePort() throws -> Int { try freeTCPPort() }

    private func waitUntilListening() throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = UInt16(port).bigEndian
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
            close(fd)
            if connected { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw NSError(domain: "TestSSHD", code: 3, userInfo: [NSLocalizedDescriptionKey: "sshd did not start on \(port)"])
    }
}
#endif

#if os(macOS)
import TabbyCore

/// A test proxy on 127.0.0.1 speaking SOCKS5 (no auth, CONNECT) or HTTP CONNECT, built on
/// the same handshake parsers the app uses. Counts the tunnels it opened.
final class TestProxy: @unchecked Sendable {
    enum Kind { case socks5, http }
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var tunnelCount = 0
    var tunnels: Int { lock.withLock { tunnelCount } }

    init(_ kind: Kind) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard ok, listen(fd, 8) == 0 else { throw NSError(domain: "TestProxy", code: 1) }
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                Thread { self.serve(client, kind) }.start()
            }
        }.start()
    }

    private func serve(_ client: Int32, _ kind: Kind) {
        var data = [UInt8]()
        func fill() -> Bool {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { return false }
            data += buffer[0..<n]
            return true
        }
        var target: (String, Int)?
        switch kind {
        case .socks5:
            while true {
                switch SOCKS5.parseGreeting(data) {
                case .needMore: if !fill() { close(client); return }; continue
                case .failure: close(client); return
                case let .done(reply, consumed):
                    _ = write(client, reply, reply.count)
                    data.removeFirst(consumed)
                }
                break
            }
            while true {
                switch SOCKS5.parseConnect(data) {
                case .needMore: if !fill() { close(client); return }; continue
                case .failure: close(client); return
                case let .done(t, consumed):
                    target = (t.host, t.port)
                    data.removeFirst(consumed)
                }
                break
            }
        case .http:
            while !String(decoding: data, as: UTF8.self).contains("\r\n\r\n") { if !fill() { close(client); return } }
            let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first ?? ""
            let authority = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if let colon = authority.lastIndex(of: ":"), let port = Int(authority[authority.index(after: colon)...]) {
                target = (String(authority[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
            }
            data.removeAll()
        }
        guard let (host, port) = target else { close(client); return }
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr(host == "localhost" ? "127.0.0.1" : host)
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        let ok: [UInt8] = kind == .socks5 ? SOCKS5.reply(connected ? .succeeded : .connectionRefused)
            : Array((connected ? "HTTP/1.1 200 Connection established\r\n\r\n" : "HTTP/1.1 502 Bad Gateway\r\n\r\n").utf8)
        _ = write(client, ok, ok.count)
        guard connected else { close(upstream); close(client); return }
        lock.withLock { tunnelCount += 1 }
        Thread { Self.pump(upstream, client) }.start()
        Self.pump(client, upstream)
    }

    private static func pump(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let n = read(from, &buffer, buffer.count)
            if n <= 0 { break }
            _ = write(to, buffer, n)
        }
        shutdown(to, SHUT_WR)
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }
}
#endif

#if os(macOS)
/// A throwaway ssh-agent on a temp socket holding the given keys (never the user's agent).
final class TestAgent {
    let socketPath: String
    private let process = Process()

    init(directory: URL, keys: [String]) throws {
        socketPath = directory.appendingPathComponent("agent.sock").path
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        process.arguments = ["-D", "-a", socketPath]
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: socketPath), Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        for key in keys {
            TestSSHD.run("/usr/bin/ssh-add", [key], environment: ["SSH_AUTH_SOCK": socketPath])
        }
    }

    func stop() {
        TestSSHD.end(process)
    }

    deinit { stop() }
}
#endif

#if os(macOS)
/// Holds a 127.0.0.1 port open so a forward on it fails.
final class PortListenerHog {
    let port: Int
    private let fd: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, length) == 0 && getsockname(socketFD, $0, &length) == 0
            }
        }
        guard ok, listen(socketFD, 1) == 0 else { throw NSError(domain: "PortListenerHog", code: 1) }
        fd = socketFD
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func stop() { close(fd) }
}
#endif

#if os(macOS)
/// A TCP server that sends `size` bytes to each client and closes (a forward's target).
final class FloodServer: @unchecked Sendable {
    let port: Int
    let payload: Data
    private let listener: Int32

    init(size: Int) throws {
        payload = Data((0..<size).map { UInt8($0 % 251) })
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        listener = fd
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard ok, listen(fd, 8) == 0 else { throw NSError(domain: "FloodServer", code: 1) }
        port = Int(UInt16(bigEndian: address.sin_port))
        let data = payload
        Thread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var yes: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                Thread {
                    data.withUnsafeBytes { raw in
                        var offset = 0
                        while offset < raw.count {
                            let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                            if n <= 0 { break }
                            offset += n
                        }
                    }
                    close(client)
                }.start()
            }
        }.start()
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }
}
#endif

#if os(macOS)
/// A listening Unix socket (stands in for an X server).
final class UnixListener {
    private let fd: Int32
    let path: String

    init(path: String) throws {
        self.path = path
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0 }
        }
        guard ok, listen(fd, 4) == 0 else { throw NSError(domain: "UnixListener", code: 1) }
    }

    func stop() {
        close(fd)
        unlink(path)
    }
}
#endif
