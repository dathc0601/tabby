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
                throw SSHConnectionError.channelFailed("Failed to forward port \(forward.summary): \(reason)")
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
        do {
            switch forward.type {
            case .local:
                let box = try openDirectTCPIP(host: forward.targetAddress, port: forward.targetPort, deliverTo: client)
                bridge(box, fd: client)
            case .dynamic:
                // A local client sends its SOCKS request at once; wait for it a little. (An
                // accepted socket inherits the listener's O_NONBLOCK on macOS.)
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                guard let reply = Self.readHandshake(client, SOCKS5.parseGreeting) else { close(client); return }
                _ = reply.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                guard reply == SOCKS5.noAuthAccepted, let target = Self.readHandshake(client, SOCKS5.parseConnect) else {
                    if reply == SOCKS5.noAuthAccepted {
                        let refusal = SOCKS5.reply(.commandNotSupported)
                        _ = refusal.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                    }
                    close(client); return
                }
                do {
                    let box = try openDirectTCPIP(host: target.host, port: target.port, deliverTo: client)
                    let ok = SOCKS5.reply(.succeeded)
                    _ = ok.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                    bridge(box, fd: client)
                } catch {
                    let refusal = SOCKS5.reply(.connectionRefused)
                    _ = refusal.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count) }
                    throw error
                }
            case .remote:
                close(client)
                return
            }
            reapChannels()
        } catch {
            close(client)
        }
    }

    /// A server-side forward's connection: matched by port and joined to its local target.
    fileprivate func acceptForwarded(destinationAddress: String, destinationPort: Int, originator: String) -> ssh_channel? {
        guard let session else { return nil }
        guard let runtime = forwardRuntimes.values.first(where: { $0.forward.type == .remote && $0.boundPort == destinationPort }) else {
            say("Rejected incoming forwarded connection for unrecognized port \(destinationAddress):\(destinationPort)")
            return nil
        }
        guard let fd = try? ProxyTunnel.connect(host: runtime.forward.targetAddress, port: runtime.forward.targetPort, timeout: 5) else {
            say("Could not connect to \(runtime.forward.targetAddress):\(runtime.forward.targetPort) for \(runtime.forward.summary)")
            return nil
        }
        return acceptBridged(session, fd: fd)
    }

    // MARK: Sockets

    static func listenTCP(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo(ai_flags: AI_PASSIVE, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host.isEmpty ? nil : host, String(port), &hints, &list) == 0, let info = list else {
            throw ForwardError.failed("cannot resolve \(host)")
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

    private static func readHandshake<T>(_ fd: Int32, _ parse: ([UInt8]) -> HandshakeStep<T>) -> T? {
        var data = [UInt8]()
        while data.count < 600 {
            switch parse(data) {
            case let .done(value, _): return value
            case .failure: return nil
            case .needMore: break
            }
            var byte: UInt8 = 0
            guard read(fd, &byte, 1) == 1 else { return nil }
            data.append(byte)
        }
        return nil
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
#endif
