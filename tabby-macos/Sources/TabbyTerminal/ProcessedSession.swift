import Foundation
import TabbyCore

/// A serial or telnet session seen through the profile's stream processing: newline
/// translation, local echo, the line editor and the hexdump (Tabby's
/// `TerminalStreamProcessor` middleware). Service lines from the session skip the
/// processing, as Tabby writes them straight to the frontend.
public final class ProcessedSession: TerminalSession {
    public let inner: TerminalSession
    public let processor: StreamProcessor

    public var onOutput: ((Data) -> Void)?
    public var onClosed: ((Int32?) -> Void)?
    public var onStatus: ((SessionStatus) -> Void)?

    /// How long output must be quiet before the line editor's prompt is drawn again.
    public var settleDelay: TimeInterval = 0.5
    private var settleWork: DispatchWorkItem?

    public init(inner: TerminalSession, options: StreamOptions) {
        self.inner = inner
        processor = StreamProcessor(options)
    }

    public var isRunning: Bool { inner.isRunning }

    public func start(cols: Int, rows: Int) throws {
        inner.onOutput = { [weak self] data in
            guard let self else { return }
            self.show(self.processor.fromSession(data))
        }
        inner.onClosed = { [weak self] code in
            self?.settleWork?.cancel()
            self?.onClosed?(code)
        }
        inner.onStatus = { [weak self] status in self?.onStatus?(status) }
        (inner as? ServiceOutputSource)?.onServiceOutput = { [weak self] data in
            guard let self else { return }
            self.show(self.processor.clearPrompt() + data)
        }
        (inner as? LocalEchoSource)?.onLocalEchoChanged = { [weak self] on in self?.processor.forceEcho = on }
        (inner as? LocalEchoSource)?.onPeerEchoChanged = { [weak self] on in self?.processor.peerEchoes = on }
        try inner.start(cols: cols, rows: rows)
        scheduleSettle()
    }

    public func write(_ data: Data) {
        let result = processor.fromTerminal(data)
        if !result.toSession.isEmpty { inner.write(result.toSession) }
        show(result.toTerminal)
    }

    public func resize(cols: Int, rows: Int) { inner.resize(cols: cols, rows: rows) }

    public func kill() {
        settleWork?.cancel()
        inner.kill()
    }

    public func workingDirectory() -> String? { inner.workingDirectory() }
    public func activeProcessName() -> String? { inner.activeProcessName() }

    private func show(_ data: Data) {
        guard !data.isEmpty else { return }
        onOutput?(data)
        scheduleSettle()
    }

    private func scheduleSettle() {
        guard processor.usesLineEditor else { return }
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.inner.isRunning else { return }
            let prompt = self.processor.outputSettled()
            if !prompt.isEmpty { self.onOutput?(prompt) }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay, execute: work)
    }
}
