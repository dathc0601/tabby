import Foundation
import TabbyCore

public enum ZModemDirection: Sendable { case receive, send }

public enum ZModemOutcome: Equatable, Sendable {
    case done, skipped, cancelled
    case failed(String)
}

/// The app's side of one transferred file (a row in the transfers popover).
public protocol ZModemTransferHandle: AnyObject {
    /// The user cancelled it (the popover's ×).
    var isCancelled: Bool { get }
    func progress(_ bytes: UInt64)
    func finish(_ outcome: ZModemOutcome)
}

/// Where a received file goes.
public protocol ZModemFileSink: ZModemTransferHandle {
    func write(_ bytes: [UInt8]) throws
}

/// A file to send and its row.
public final class ZModemUpload {
    public let file: ZModemOutgoingFile
    public let handle: ZModemTransferHandle

    public init(file: ZModemOutgoingFile, handle: ZModemTransferHandle) {
        self.file = file
        self.handle = handle
    }
}

/// The app's part of a pane's ZMODEM sessions: the question, where files go, what is sent.
public protocol ZModemHost: AnyObject {
    func zmodemAsk(_ direction: ZModemDirection, in pane: TerminalPane, answer: @escaping (Bool) -> Void)
    func zmodemSave(_ info: ZModemFileInfo, in pane: TerminalPane, answer: @escaping (ZModemFileSink?) -> Void)
    func zmodemChooseFiles(in pane: TerminalPane, answer: @escaping ([ZModemUpload]) -> Void)
}

/// Tabby's `ZModemMiddleware` for one pane: watches the session's output for a ZMODEM session,
/// asks, then runs it (TabbyCore's receiver or sender) while writing Tabby's status lines into
/// the terminal. Keys still reach the remote; Ctrl-C cancels the current file (then the session).
public final class ZModemBridge {
    /// Bytes for the session.
    public var toRemote: ([UInt8]) -> Void = { _ in }
    /// Output that is the terminal's (the pane carries on with it).
    public var toTerminal: ([UInt8]) -> Void = { _ in }
    /// A status line, written to the terminal as is.
    public var showLine: (String) -> Void = { _ in }
    /// Asks whether to accept a session (Tabby: "Accept a ZMODEM session?").
    public var ask: (ZModemDirection, @escaping (Bool) -> Void) -> Void = { _, answer in answer(false) }
    /// Where to save an offered file; nil skips it.
    public var save: (ZModemFileInfo, @escaping (ZModemFileSink?) -> Void) -> Void = { _, answer in answer(nil) }
    /// The files to send; none ends the session.
    public var chooseFiles: (@escaping ([ZModemUpload]) -> Void) -> Void = { answer in answer([]) }
    /// Runs data batches later (the main queue in the app).
    public var schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    /// Runs `work` after a pause.
    public var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// The clock (tests set it).
    public var now: () -> Date = { Date() }
    /// A session with nothing from the remote for this long ends (sz/rz died, say), so the
    /// terminal comes back. Not while a panel waits for the user.
    public var stallTimeout: TimeInterval = 15
    private var lastRemote = Date.distantPast
    private var watchPending = false
    private var waitingForUser = false
    /// Tabby: a progress line at most every 500 ms.
    public var progressInterval: TimeInterval = 0.5

    private enum State {
        case watching
        case asking(ZModemDirection, [UInt8])
        case choosing([UInt8])
        case receiving(ZModemReceiver)
        case sending(ZModemSender)
    }

    private var state = State.watching
    private var sentry = ZModemSentry()
    /// After a rejection, sz/rz go on sending headers for a while; those are dropped. Each
    /// refusal doubles the quiet time (2 s, 4 s, … 1 min), so a remote can't keep asking.
    private var ignoreUntil: Date?
    private var quietTime: TimeInterval = 1
    /// Output held while the question or a panel is up; more than this refuses the session.
    public static let maxHeld = 1024 * 1024
    private var current: (info: ZModemFileInfo, sink: ZModemFileSink, received: UInt64)?
    private var uploads: [ZModemUpload] = []
    private var sendingIndex: Int?
    private var cancelledUploads = Set<Int>()
    private var lastProgressLine = Date.distantPast
    private var generation = 0

    public init() {}

    public var isActive: Bool {
        if case .watching = state { return false }
        return true
    }

    // MARK: Output from the session

    public func fromRemote(_ bytes: [UInt8]) {
        switch state {
        case .watching:
            let result = sentry.feed(bytes)
            if !result.toTerminal.isEmpty { toTerminal(result.toTerminal) }
            generation += 1
            if sentry.isHolding {
                let run = generation
                after(0.3) { [weak self] in
                    guard let self, run == self.generation, case .watching = self.state, self.sentry.isHolding else { return }
                    self.toTerminal(self.sentry.flush())
                }
            }
            guard let detection = result.detection else { return }
            let direction: ZModemDirection = detection == .receive ? .receive : .send
            if let until = ignoreUntil, now() < until {
                // A repeat of a refused session's header: drop it (and its line end), keep the
                // rest — often the shell's prompt once sz/rz gave up.
                let rest = result.protocolBytes.dropFirst(result.headerLength).drop { [0x0D, 0x8D, 0x0A, 0x8A, 0x11].contains($0) }
                if !rest.isEmpty { fromRemote(Array(rest)) }
                return
            }
            state = .asking(direction, result.protocolBytes)
            ask(direction) { [weak self] ok in self?.answered(direction, ok) }
        case .asking(let direction, let held):
            guard held.count + bytes.count <= Self.maxHeld else { return refuse() }
            state = .asking(direction, held + bytes)
        case .choosing(let held):
            guard held.count + bytes.count <= Self.maxHeld else { return refuse() }
            state = .choosing(held + bytes)
        case .receiving(let receiver):
            heardFromRemote()
            receiver.feed(bytes)
            if receiver.isEnding {
                // Some senders never write "OO".
                after(1) { [weak receiver] in receiver?.endWithoutOverAndOut() }
            }
        case .sending(let sender):
            heardFromRemote()
            sender.feed(bytes)
        }
    }

    private func heardFromRemote() {
        lastRemote = now()
        watchForSilence()
    }

    private func watchForSilence() {
        guard !watchPending else { return }
        watchPending = true
        after(stallTimeout) { [weak self] in
            guard let self else { return }
            self.watchPending = false
            switch self.state {
            case .receiving, .sending:
                if self.waitingForUser || self.now().timeIntervalSince(self.lastRemote) < self.stallTimeout {
                    self.watchForSilence()
                } else {
                    self.toRemote(ZModem.abortSequence)
                    self.failed(L("no answer from the remote"))
                }
            default:
                break
            }
        }
    }

    // MARK: Input from the user

    /// Keys typed while a session runs go to the remote as usual; a lone Ctrl-C also cancels
    /// the current file, or the session when no file is in progress.
    public func userInput(_ bytes: [UInt8]) {
        guard bytes == [0x03] else { return }
        switch state {
        case .receiving(let receiver):
            if current != nil { cancelCurrentReceive(receiver) } else { receiver.cancel() }
        case .sending(let sender):
            if let index = sendingIndex, !cancelledUploads.contains(index) {
                cancelledUploads.insert(index)
                sender.skipCurrent()
            } else {
                sender.cancel()
            }
        default:
            break
        }
    }

    // MARK: Session

    private func answered(_ direction: ZModemDirection, _ ok: Bool) {
        guard case .asking(_, let held) = state else { return }
        guard ok else { return refuse() }
        line(Self.label("ZMODEM", .blue), L("Session started")) // l10n-ignore: the protocol's name
        line("------------------------", nil) // l10n-ignore: a rule
        lastRemote = now()
        switch direction {
        case .receive:
            let receiver = makeReceiver()
            state = .receiving(receiver)
            watchForSilence()
            receiver.start()
            receiver.feed(held)
        case .send:
            state = .choosing(held)
            chooseFiles { [weak self] uploads in self?.startSending(uploads) }
        }
    }

    /// Tells the remote no (lrzsz's CAN sequence) and keeps quiet for a while.
    private func refuse() {
        toRemote(ZModem.abortSequence)
        line(Self.label(L("Rejected"), .red), L("ZMODEM session"))
        quietTime = min(quietTime * 2, 60)
        ignoreUntil = now().addingTimeInterval(quietTime)
        endSession()
    }

    private func makeReceiver() -> ZModemReceiver {
        let receiver = ZModemReceiver()
        receiver.toRemote = { [weak self] in self?.toRemote($0) }
        receiver.onOffer = { [weak self, weak receiver] info in
            guard let self else { return }
            self.line(Self.label(L("Offered"), .yellow), info.name, overwrite: true)
            self.waitingForUser = true
            self.save(info) { [weak self, weak receiver] sink in
                guard let self, let receiver else { return }
                self.waitingForUser = false
                self.lastRemote = self.now()
                if let sink {
                    self.current = (info, sink, 0)
                    receiver.accept()
                } else {
                    self.line(Self.label(L("Rejected"), .red), info.name)
                    receiver.skip()
                }
            }
        }
        receiver.onData = { [weak self, weak receiver] data in
            guard let self, let receiver, var cur = self.current else { return }
            do {
                try cur.sink.write(data)
            } catch {
                self.line(Self.label(L("Error"), .red), cur.info.name)
                cur.sink.finish(.failed(error.localizedDescription))
                self.current = nil
                receiver.skipCurrent()
                return
            }
            cur.received += UInt64(data.count)
            self.current = cur
            cur.sink.progress(cur.received)
            if cur.sink.isCancelled { return self.cancelCurrentReceive(receiver) }
            self.progressLine(cur.info.name, cur.received, cur.info.size)
        }
        receiver.onFileEnd = { [weak self] in
            guard let self, let cur = self.current else { return }
            self.current = nil
            cur.sink.finish(.done)
            self.line(Self.label(L("Received"), .green), cur.info.name)
        }
        receiver.onFinished = { [weak self] rest in self?.finished(rest) }
        receiver.onError = { [weak self] reason in self?.failed(reason) }
        return receiver
    }

    private func cancelCurrentReceive(_ receiver: ZModemReceiver) {
        guard let cur = current else { return }
        current = nil
        cur.sink.finish(.cancelled)
        line(Self.label(L("Canceled"), .red), cur.info.name)
        receiver.skipCurrent()
    }

    private func startSending(_ uploads: [ZModemUpload]) {
        guard case .choosing(let held) = state else { return }
        self.uploads = uploads
        cancelledUploads = []
        let sender = ZModemSender(files: uploads.map(\.file))
        sender.schedule = { [weak self] work in self?.schedule(work) }
        sender.after = { [weak self] delay, work in self?.after(delay, work) }
        sender.toRemote = { [weak self] in self?.toRemote($0) }
        sender.onFileStart = { [weak self] index in
            guard let self else { return }
            self.sendingIndex = index
            self.line(Self.label(L("Offered"), .yellow), uploads[index].file.info.name, overwrite: true)
        }
        sender.onProgress = { [weak self, weak sender] index, sent in
            guard let self else { return }
            let upload = uploads[index]
            upload.handle.progress(sent)
            if upload.handle.isCancelled, !self.cancelledUploads.contains(index) {
                self.cancelledUploads.insert(index)
                sender?.skipCurrent()
                return
            }
            self.progressLine(upload.file.info.name, sent, upload.file.info.size)
        }
        sender.onFileDone = { [weak self] index, skipped in
            guard let self else { return }
            self.sendingIndex = nil
            let upload = uploads[index]
            if skipped {
                upload.handle.finish(.skipped)
                self.line(Self.label(L("Rejected"), .red), upload.file.info.name)
            } else if self.cancelledUploads.contains(index) {
                upload.handle.finish(.cancelled)
                self.line(Self.label(L("Canceled"), .red), upload.file.info.name)
            } else {
                upload.handle.finish(.done)
                self.line(Self.label(L("Sent"), .green), upload.file.info.name)
            }
        }
        sender.onFinished = { [weak self] rest in self?.finished(rest) }
        sender.onError = { [weak self] reason in self?.failed(reason) }
        state = .sending(sender)
        lastRemote = now()
        watchForSilence()
        sender.feed(held)
    }

    private func finished(_ rest: [UInt8]) {
        endSession()
        line(Self.label(L("Complete"), .blue), nil)
        if !rest.isEmpty { fromRemote(rest) }
    }

    private func failed(_ reason: String) {
        if let cur = current {
            cur.sink.finish(.cancelled)
            current = nil
        }
        if let index = sendingIndex, uploads.indices.contains(index) {
            uploads[index].handle.finish(.cancelled)
        }
        endSession()
        line(Self.label("ZMODEM", .red), L("Session failed: {reason}", ["reason": reason])) // l10n-ignore: the protocol's name
    }

    /// The session ended or the pane closed mid-transfer: open files are given up.
    public func abandon() {
        guard isActive else { return }
        if let cur = current {
            cur.sink.finish(.cancelled)
            current = nil
        }
        if let index = sendingIndex, uploads.indices.contains(index) { uploads[index].handle.finish(.cancelled) }
        if case .sending(let sender) = state { sender.cancel() }
        endSession()
    }

    private func endSession() {
        state = .watching
        waitingForUser = false
        sentry = ZModemSentry()
        sendingIndex = nil
        uploads = []
    }

    // MARK: Status lines (Tabby's `showMessage`)

    enum Colour: Int { case red = 41, green = 42, yellow = 43, blue = 44 }

    /// Black text on a coloured background, as Tabby's ansi-colors labels.
    static func label(_ text: String, _ colour: Colour) -> String {
        "\u{1b}[30m\u{1b}[\(colour.rawValue)m \(text) \u{1b}[49m\u{1b}[39m"
    }

    private func line(_ label: String, _ text: String?, overwrite: Bool = false) {
        let body = text.map { label + " " + $0 } ?? label
        showLine("\r" + body + String(repeating: " ", count: 12) + (overwrite ? "" : "\r\n"))
    }

    private func progressLine(_ name: String, _ done: UInt64, _ total: UInt64?) {
        let now = Date()
        guard now.timeIntervalSince(lastProgressLine) >= progressInterval || done == total else { return }
        lastProgressLine = now
        let percent = total.map { $0 > 0 ? Int((Double(done) / Double($0) * 100).rounded()) : 100 } ?? 0
        let padded = String(repeating: " ", count: max(0, 3 - String(percent).count)) + "\(percent)%"
        line(Self.label(padded, .yellow), name, overwrite: true)
    }
}
