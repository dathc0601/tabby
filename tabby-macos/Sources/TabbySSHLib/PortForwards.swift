#if os(macOS)
import CLibSSH
import Foundation
import TabbyCore

/// A forward on a connection, as the Ports popover lists it.
public struct ForwardStatus: Equatable, Sendable {
    public let id: UUID
    public let forward: ForwardedPort
}

/// A running forward (connection thread only).
final class ForwardRuntime {
    let id = UUID()
    let forward: ForwardedPort
    var listener: Int32 = -1
    var boundPort = 0
    weak var connection: SSHConnection?

    init(_ forward: ForwardedPort) {
        self.forward = forward
    }
}

extension SSHConnection {
    /// The forwards running on this connection.
    public var forwards: [ForwardStatus] {
        lock.withLock { forwardList }
    }

    /// Starts a forward: a local listener (local, dynamic) or a server-side one (remote).
    public func addForward(_ forward: ForwardedPort) async throws -> UUID {
        try await perform { [self] in
            let runtime = ForwardRuntime(forward)
            runtime.connection = self
            do {
                switch forward.type {
                case .local, .dynamic:
                    runtime.listener = try Self.listenTCP(host: forward.host, port: forward.port)
                    ssh_event_add_fd(event, runtime.listener, Int16(POLLIN), forwardAccept,
                                     Unmanaged.passUnretained(runtime).toOpaque())
                case .remote:
                    var bound: Int32 = 0
                    guard let session, ssh_channel_listen_forward(session, forward.host, Int32(forward.port), &bound) == SSH_OK else {
                        throw ForwardError.failed(lastError())
                    }
                    runtime.boundPort = bound > 0 ? Int(bound) : forward.port
                }
            } catch let ForwardError.failed(reason) {
                throw SSHConnectionError.forwardFailed(summary: forward.summary, reason: reason)
            }
            forwardRuntimes[runtime.id] = runtime
            publishForwards()
            return runtime.id
        }
    }

    /// Stops a forward; connections already made through it carry on.
    public func removeForward(_ id: UUID) async {
        _ = try? await perform { [self] in
            guard let runtime = forwardRuntimes.removeValue(forKey: id) else { return }
            stop(runtime)
            publishForwards()
        }
    }

    // MARK: Connection thread

    private enum ForwardError: Error { case failed(String) }

    private func stop(_ runtime: ForwardRuntime) {
        if runtime.listener >= 0 {
            if let event { ssh_event_remove_fd(event, runtime.listener) }
            close(runtime.listener)
            runtime.listener = -1
        } else if runtime.forward.type == .remote, let session {
            ssh_channel_cancel_forward(session, runtime.forward.host, Int32(runtime.forward.port))
        }
    }

    func closeForwards() {
        for runtime in forwardRuntimes.values where runtime.listener >= 0 {
            if let event { ssh_event_remove_fd(event, runtime.listener) }
            close(runtime.listener)
            runtime.listener = -1
        }
        forwardRuntimes.removeAll()
        publishForwards()
    }

    private func publishForwards() {
        let list = forwardRuntimes.values.sorted { $0.forward.port < $1.forward.port }.map { ForwardStatus(id: $0.id, forward: $0.forward) }
        lock.withLock { forwardList = list }
        onForwardsChanged?(list)
    }

    /// New clients on a local or dynamic forward. Channels are opened after the current poll.
    fileprivate func acceptClients(_ runtime: ForwardRuntime) {
        while true {
            let client = accept(runtime.listener, nil, nil)
            guard client >= 0 else { return }
            var yes: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            enqueue { [self] in serve(client, through: runtime) }
        }
    }

    private func serve(_ client: Int32, through runtime: ForwardRuntime) {
        let forward = runtime.forward
        switch forward.type {
        case .local:
            startDirectTCPIP(host: forward.targetAddress, port: forward.targetPort) { [self] result in
                switch result {
                case .success(let box): bridge(box, fd: client)
                case .failure: close(client)
                }
            }
        case .dynamic:
            // The handshake runs on the event loop (SOCKSClient), never blocking it.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            socksClients.append(SOCKSClient(fd: client))
        case .remote:
            close(client)
        }
    }

    // MARK: SOCKS clients (dynamic forwards)

    /// Between polls: register clients that wait for bytes, open channels for clients that
    /// asked for a target, drop clients that took too long.
    func serviceSOCKSClients() {
        guard !socksClients.isEmpty else { return }
        for client in socksClients {
            if client.stage == .greeting || client.stage == .request, Date() > client.deadline { client.stage = .failed }
            switch client.stage {
            case .greeting, .request:
                if !client.registered, let event {
                    ssh_event_add_fd(event, client.fd, Int16(POLLIN), socksReadable, Unmanaged.passUnretained(client).toOpaque())
                    client.registered = true
                }
            case .open(let target):
                unregister(client)
                client.stage = .opening
                startDirectTCPIP(host: target.host, port: target.port) { [self] result in
                    switch result {
                    case .success(let box):
                        Self.send(client.fd, SOCKS5.reply(.succeeded))
                        bridge(box, fd: client.fd)
                        client.stage = .handedOver
                    case .failure:
                        Self.send(client.fd, SOCKS5.reply(.connectionRefused))
                        client.stage = .failed
                    }
                }
            case .opening, .handedOver, .failed:
                break
            }
        }
        socksClients.removeAll { client in
            switch client.stage {
            case .handedOver:
                unregister(client)
                return true
            case .failed:
                unregister(client)
                close(client.fd)
                return true
            default:
                return false
            }
        }
    }

    private func unregister(_ client: SOCKSClient) {
        guard client.registered else { return }
        if let event { ssh_event_remove_fd(event, client.fd) }
        client.registered = false
    }

    func closeSOCKSClients() {
        for client in socksClients {
            unregister(client)
            if client.stage != .handedOver { close(client.fd) }
        }
        socksClients.removeAll()
    }

    static func send(_ fd: Int32, _ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }

    /// A server-side forward's connection: matched by port and joined to its local target.
    fileprivate func acceptForwarded(destinationAddress: String, destinationPort: Int, originator: String) -> ssh_channel? {
        guard let session else { return nil }
        guard let runtime = forwardRuntimes.values.first(where: { $0.forward.type == .remote && $0.boundPort == destinationPort }) else {
            say(L("Rejected incoming forwarded connection for unrecognized port {destinationAddress}:{destinationPort}", ["destinationAddress": destinationAddress, "destinationPort": destinationPort]))
            return nil
        }
        // Not waited for here (inside a libssh callback): the bridge waits for the connect.
        guard let fd = LocalSocket.startTCP(host: runtime.forward.targetAddress, port: runtime.forward.targetPort) else {
            say(L("Could not connect to {targetAddress}:{targetPort} for {summary}", ["targetAddress": runtime.forward.targetAddress, "targetPort": runtime.forward.targetPort, "summary": runtime.forward.summary]))
            return nil
        }
        return acceptBridged(session, fd: fd, connecting: true)
    }

    // MARK: Sockets

    static func listenTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_PASSIVE, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.isEmpty ? nil : host, String(port), &hints, &list) == 0, let info = list else {
            throw ForwardError.failed(L("cannot resolve {host}", ["host": host]))
        }
        defer { freeaddrinfo(list) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { throw ForwardError.failed(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard bind(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno)).lowercased()
            close(fd)
            throw ForwardError.failed(reason)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

}

private let forwardAccept: ssh_event_callback = { _, _, userdata in
    let runtime = Unmanaged<ForwardRuntime>.fromOpaque(userdata!).takeUnretainedValue()
    runtime.connection?.acceptClients(runtime)
    return 0
}

let forwardedChannelRequested: ssh_channel_open_request_forwarded_tcpip_callback = { _, destination, port, originator, _, userdata in
    Unmanaged<SSHConnection>.fromOpaque(userdata!).takeUnretainedValue().acceptForwarded(
        destinationAddress: destination.map { String(cString: $0) } ?? "", destinationPort: Int(port),
        originator: originator.map { String(cString: $0) } ?? "")
}
/// A dynamic forward's client during its SOCKS5 handshake (connection thread).
final class SOCKSClient {
    enum Stage: Equatable {
        case greeting, request
        case open(SOCKS5.Target)
        case opening, handedOver, failed
    }

    let fd: Int32
    var stage: Stage = .greeting
    var registered = false
    let deadline = Date().addingTimeInterval(10)
    private var data: [UInt8] = []

    init(fd: Int32) {
        self.fd = fd
    }

    /// Reads what arrived and moves the handshake on (inside a poll callback: no libssh calls).
    func readable() {
        var buffer = [UInt8](repeating: 0, count: 512)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else {
            if n == 0 || (errno != EAGAIN && errno != EINTR) { stage = .failed }
            return
        }
        data += buffer[0..<n]
        guard data.count <= 1024 else { return stage = .failed }
        if stage == .greeting {
            switch SOCKS5.parseGreeting(data) {
            case .needMore: return
            case .failure: return stage = .failed
            case let .done(reply, consumed):
                SSHConnection.send(fd, reply)
                data.removeFirst(consumed)
                guard reply == SOCKS5.noAuthAccepted else { return stage = .failed }
                stage = .request
            }
        }
        if stage == .request {
            switch SOCKS5.parseConnect(data) {
            case .needMore: return
            case .failure:
                SSHConnection.send(fd, SOCKS5.reply(.commandNotSupported))
                stage = .failed
            case let .done(target, _):
                stage = .open(target)
            }
        }
    }
}

private let socksReadable: ssh_event_callback = { _, _, userdata in
    Unmanaged<SOCKSClient>.fromOpaque(userdata!).takeUnretainedValue().readable()
    return 0
}
#endif
