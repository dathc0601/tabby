import Foundation
import TabbyIPC

/// Receives prompts from `tabby-askpass` over a Unix socket and routes them to the SSH
/// session that spawned the helper. One server per app.
public final class AskpassServer {
    public typealias Handler = (AskpassRequest, @escaping (AskpassResponse) -> Void) -> Void

    public let socketPath: String
    private var listener: Int32 = -1
    private var handlers: [String: (token: String, handler: Handler)] = [:]
    private let lock = NSLock()

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// A short per-user path (sun_path is limited to 104 bytes on macOS).
    public static func defaultSocketPath() -> String {
        let dir = runtimeDirectory()
        return "\(dir)/askpass-\(getpid()).sock"
    }

    /// `/tmp/tabbymac-<uid>`, created with mode 0700. Also used for ControlMaster sockets.
    public static func runtimeDirectory() -> String {
        let dir = "/tmp/tabbymac-\(getuid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
        return dir
    }

    deinit { stop() }

    public func start() throws {
        guard listener < 0 else { return }
        listener = try UnixSocket.listen(path: socketPath)
        let fd = listener
        let thread = Thread { [weak self] in
            while true {
                let client = UnixSocket.accept(fd)
                if client < 0 { return }
                guard let self else { UnixSocket.closeSocket(client); return }
                Thread.detachNewThread { self.serve(client) }
            }
        }
        thread.name = "TabbyMac.askpass.accept"
        thread.start()
    }

    public func stop() {
        if listener >= 0 {
            shutdown(listener, Int32(SHUT_RDWR))
            UnixSocket.closeSocket(listener)
            listener = -1
            unlink(socketPath)
        }
    }

    public func register(session: String, token: String, handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[session] = (token, handler)
    }

    public func unregister(session: String) {
        lock.lock(); defer { lock.unlock() }
        handlers[session] = nil
    }

    private func serve(_ client: Int32) {
        defer { UnixSocket.closeSocket(client) }
        guard let line = UnixSocket.readLine(client),
              let request = try? JSONDecoder().decode(AskpassRequest.self, from: Data(line.utf8)) else { return }
        lock.lock()
        let entry = handlers[request.session]
        lock.unlock()
        guard let entry, entry.token == request.token else {
            respond(client, AskpassResponse(ok: false))
            return
        }
        let done = DispatchSemaphore(value: 0)
        var response = AskpassResponse(ok: false)
        DispatchQueue.main.async {
            entry.handler(request) { r in
                response = r
                done.signal()
            }
        }
        // Wait for the user; ssh itself times out long before this.
        _ = done.wait(timeout: .now() + .seconds(600))
        respond(client, response)
    }

    private func respond(_ client: Int32, _ response: AskpassResponse) {
        if let data = try? JSONEncoder().encode(response) {
            UnixSocket.writeLine(client, String(decoding: data, as: UTF8.self))
        }
    }
}
