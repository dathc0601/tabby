// TabbyTelnet: telnet and raw TCP sessions (phase 4) over Network.framework, with the
// protocol handled by TabbyCore's `TelnetProtocol`. Port of `tabby-telnet/src`.
#if canImport(Network)
import Foundation
import Network
import TabbyCore
import TabbyTerminal

/// One telnet (or raw socket) connection behind a pane. Port of Tabby's `TelnetSession`
/// (`tabby-telnet/src/session.ts`). Stream processing is applied around it by
/// `ProcessedSession`; the peer's echo requests reach that through `LocalEchoSource`.
/// All callbacks run on the main queue.
public final class TelnetSession: TerminalSession, ServiceOutputSource, LocalEchoSource {
    public enum Failure: LocalizedError {
        case noHost
        case badPort(Int)

        public var errorDescription: String? {
            switch self {
            case .noHost: return L("No host to connect to")
            case .badPort(let port): return L("Invalid port {port}", ["port": port])
            }
        }
    }

    public var onOutput: ((Data) -> Void)?
    public var onClosed: ((Int32?) -> Void)?
    public var onStatus: ((SessionStatus) -> Void)?
    public var onServiceOutput: ((Data) -> Void)?
    public var onLocalEchoChanged: ((Bool) -> Void)?
    public var onPeerEchoChanged: ((Bool) -> Void)?

    public let options: TelnetOptions
    public private(set) var isRunning = false
    /// Tabby waits forever; a host that never answers ends the attempt after this.
    public var connectTimeout: TimeInterval = 30

    private let telnet = TelnetProtocol()
    private let queue = DispatchQueue(label: "TabbyMac.telnet")
    private var connection: NWConnection?
    private var opened = false
    private var ended = false
    /// Input before the connection is up (typing while connecting, login scripts without an
    /// expect), sent once it opens; bounded like `LibSSHSession`'s.
    private var earlyInput = Data()
    static let earlyInputLimit = 64 * 1024

    public init(options: TelnetOptions) {
        self.options = options
    }

    public func start(cols: Int, rows: Int) throws {
        guard !options.host.isEmpty else { throw Failure.noHost }
        guard (1...65535).contains(options.port), let port = NWEndpoint.Port(rawValue: UInt16(options.port)) else {
            throw Failure.badPort(options.port)
        }
        telnet.resize(cols: cols, rows: rows)
        service(ServiceMessage.line(L("Connecting to {host}", ["host": options.host]), badge: .telnet))
        onStatus?(.connecting(options.host))
        let connection = NWConnection(host: NWEndpoint.Host(options.host), port: port, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { self?.handle(state) }
        }
        connection.start(queue: queue)
        isRunning = true
        let timeout = connectTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.opened, !self.ended else { return }
            self.fail(L("Connection timed out"))
        }
    }

    public func write(_ data: Data) {
        guard opened else {
            if !ended, earlyInput.count + data.count <= Self.earlyInputLimit { earlyInput.append(data) }
            return
        }
        send(telnet.send(data))
    }

    public func resize(cols: Int, rows: Int) {
        let update = telnet.resize(cols: cols, rows: rows)
        if opened, !update.isEmpty { send(update) }
    }

    public func kill() {
        guard !ended else { return }
        end()
    }

    public func workingDirectory() -> String? { nil }

    // MARK: Connection

    private func handle(_ state: NWConnection.State) {
        guard !ended else { return }
        switch state {
        case .ready:
            opened = true
            service(ServiceMessage.line(L("Connected"), badge: .telnet))
            onStatus?(.connected)
            if !earlyInput.isEmpty {
                send(telnet.send(earlyInput))
                earlyInput = Data()
            }
            receive()
        case .waiting(let error), .failed(let error):
            // `.waiting` is a refused or unreachable connect that Network would retry.
            fail(L("Socket error: {reason}", ["reason": Self.describe(error)]))
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                if let data, !data.isEmpty { self.process(data) }
                if let error {
                    self.fail(L("Socket error: {reason}", ["reason": Self.describe(error)]))
                } else if isComplete {
                    self.service(ServiceMessage.line(L("Connection closed"), badge: .telnet))
                    self.end()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func process(_ data: Data) {
        let result = telnet.receive(data)
        if !result.toPeer.isEmpty { send(result.toPeer) }
        if let echo = result.localEcho { onLocalEchoChanged?(echo) }
        if let echo = result.peerEcho { onPeerEchoChanged?(echo) }
        if !result.toTerminal.isEmpty { onOutput?(result.toTerminal) }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                self.fail(L("Socket error: {reason}", ["reason": Self.describe(error)]))
            }
        })
    }

    // MARK: Ending

    private func fail(_ message: String) {
        guard !ended else { return }
        service(ServiceMessage.error(message))
        finish()
    }

    /// The connection ended normally (peer closed, or the pane let go of it).
    private func end() {
        service(ServiceMessage.line(L("{host}: session closed", ["host": options.host]), badge: .telnet))
        finish()
    }

    private func finish() {
        ended = true
        isRunning = false
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onStatus?(.disconnected)
        onClosed?(nil)
    }

    /// Service lines go around the stream processing when a `ProcessedSession` listens.
    private func service(_ data: Data) {
        if let onServiceOutput { onServiceOutput(data) } else { onOutput?(data) }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return String(cString: strerror(code.rawValue))
        case .dns:
            return L("Host not found")
        default:
            return error.localizedDescription
        }
    }
}

/// Creates telnet sessions, wrapped in the profile's stream processing.
public final class TelnetSessionFactory: SessionFactory {
    public let profileType = "telnet"

    public init() {}

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        ProcessedSession(inner: TelnetSession(options: TelnetOptions(profile.options)), options: StreamOptions(profile.options))
    }
}
#endif
