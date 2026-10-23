#if os(macOS)
import Foundation
import TabbyCore
import TabbyTerminal

/// One serial port behind a pane. Port of Tabby's `SerialSession`
/// (`tabby-serial/src/api.ts`) with the messages of its `SerialTabComponent`. Stream
/// processing is applied around it by `ProcessedSession`. Callbacks run on the main queue.
public final class SerialSession: TerminalSession, ServiceOutputSource {
    public var onOutput: ((Data) -> Void)?
    public var onClosed: ((Int32?) -> Void)?
    public var onStatus: ((SessionStatus) -> Void)?
    public var onServiceOutput: ((Data) -> Void)?

    public private(set) var options: SerialOptions
    public private(set) var isRunning = false
    /// The rate in use (the profile's, or quick connect's 115200 when it has none).
    public var baudRate: Int { options.baudrate ?? BaudRates.quickConnectDefault }

    private var port: SerialPort?
    private var ended = false

    public init(options: SerialOptions) {
        self.options = options
    }

    public func start(cols: Int, rows: Int) throws {
        isRunning = true
        guard let path = options.port else {
            failLater("No serial port selected")
            return
        }
        let port = SerialPort(path: path)
        port.onData = { [weak self] data in self?.onOutput?(data) }
        port.onHangup = { [weak self] in
            guard let self, !self.ended else { return }
            self.service(ServiceMessage.line("Port closed", badge: .serial))
            self.end()
        }
        do {
            try port.open(SerialPort.Settings(options, baudRate: baudRate))
        } catch {
            failLater((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return
        }
        self.port = port
        service(ServiceMessage.line("Port opened", badge: .serial))
        onStatus?(.connected)
    }

    public func write(_ data: Data) {
        guard let port else { return }
        for chunk in Self.writes(for: data, slowSend: options.slowSend) { port.write(chunk) }
    }

    /// Tabby's "Slow feed" sends one byte per write (with no delay in between).
    static func writes(for data: Data, slowSend: Bool) -> [Data] {
        slowSend ? data.map { Data([$0]) } : [data]
    }

    /// Serial lines carry no window size.
    public func resize(cols: Int, rows: Int) {}

    public func kill() {
        guard !ended else { return }
        end()
    }

    public func workingDirectory() -> String? { nil }

    /// "Change baud rate": applied to the open port at once.
    public func changeBaudRate(_ rate: Int) throws {
        var changed = options
        changed.baudrate = rate
        try port?.apply(SerialPort.Settings(changed, baudRate: rate))
        options = changed
    }

    // MARK: Ending

    /// A port that can't open ends the session after `start` returns, so the pane shows the
    /// error and offers to try again.
    private func failLater(_ message: String) {
        service(ServiceMessage.error(message))
        DispatchQueue.main.async { [weak self] in self?.finish() }
    }

    private func end() {
        service(ServiceMessage.line("\(options.port ?? "Serial"): session closed", badge: .serial))
        finish()
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        isRunning = false
        port?.onHangup = nil
        port?.close()
        port = nil
        onStatus?(.disconnected)
        onClosed?(nil)
    }

    private func service(_ data: Data) {
        if let onServiceOutput { onServiceOutput(data) } else { onOutput?(data) }
    }
}

/// Creates serial sessions, wrapped in the profile's stream processing.
public final class SerialSessionFactory: SessionFactory {
    public let profileType = "serial"

    public init() {}

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        ProcessedSession(inner: SerialSession(options: SerialOptions(profile.options)), options: StreamOptions(profile.options))
    }
}
#endif
