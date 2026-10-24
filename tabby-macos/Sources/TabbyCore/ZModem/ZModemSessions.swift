// l10n-ignore-file: protocol states and internal reasons; the app words what users see.
import Foundation

extension ZModemDecoder {
    /// Feeds one byte (sessions stop at the exact byte where the protocol ends).
    mutating func feed(byte: UInt8) -> ZModemEvent? { feed([byte]).first }
}

/// After both sides sent ZFIN the sender writes "OO" (over and out); whatever follows is the
/// shell again. CR/LF/XON left over from the last header are dropped first.
struct OverAndOut {
    private var os = 0

    /// Returns the bytes for the terminal once the end is past, nil while still waiting.
    mutating func feed(_ bytes: [UInt8]) -> [UInt8]? {
        var i = 0
        while i < bytes.count {
            let c = bytes[i]
            if os < 2 && c == UInt8(ascii: "O") {
                os += 1
            } else if os == 0 && [0x0D, 0x8D, 0x0A, 0x8A, 0x11].contains(c) {
                // the tail of the last header
            } else {
                return Array(bytes[i...])
            }
            i += 1
            if os == 2 { return Array(bytes[i...]) }
        }
        return nil
    }
}

/// Receiving files (the remote runs `sz`): Tabby's receive session in `zmodem.ts`.
public final class ZModemReceiver {
    /// Bytes for the remote end.
    public var toRemote: ([UInt8]) -> Void = { _ in }
    /// A file is offered; answer with `accept()` or `skip()`, now or later.
    public var onOffer: ((ZModemFileInfo) -> Void)?
    /// Bytes of the accepted file, in order.
    public var onData: (([UInt8]) -> Void)?
    /// The accepted file is complete.
    public var onFileEnd: (() -> Void)?
    /// The session ended normally; the bytes are the terminal's again.
    public var onFinished: (([UInt8]) -> Void)?
    /// The session failed or was cancelled.
    public var onError: ((String) -> Void)?

    private enum Phase { case waiting, offered, receiving, over, done }
    private var phase = Phase.waiting
    private var decoder = ZModemDecoder()
    private let encoder = ZModemEncoder()
    private var position: UInt32 = 0
    /// After a bad subpacket: data is ignored until ZDATA comes back at `position`.
    private var resyncing = false
    /// What the next data subpacket belongs to.
    private enum Awaiting { case sinit, file, ignored }
    private var awaiting: Awaiting?
    private var lastHeader: ZModemHeader?
    private var over = OverAndOut()

    /// CANFDX | CANOVIO | CANFC32, as zmodem.js offers.
    public static let capabilities = ZModem.canfdx | ZModem.canovio | ZModem.canfc32

    public init() {}

    public var isActive: Bool { phase != .done }

    public func start() { send(ZModemHeader(type: .rinit, flags: Self.capabilities)) }

    public func accept() {
        guard phase == .offered else { return }
        phase = .receiving
        position = 0
        resyncing = false
        send(ZModemHeader(type: .rpos, position: 0))
    }

    public func skip() {
        guard phase == .offered else { return }
        phase = .waiting
        send(ZModemHeader(type: .skip))
    }

    /// Gives up the file being received; lrzsz's `sz` then offers the next one.
    public func skipCurrent() {
        guard phase == .receiving else { return }
        phase = .waiting
        // Like lrzsz's rz: the data still on its way is noise; look for the next header.
        decoder.seekHeader()
        send(ZModemHeader(type: .skip))
    }

    /// Both sides sent ZFIN; "OO" is due.
    public var isEnding: Bool { phase == .over }

    /// The user cancelled: the remote is told with lrzsz's CAN sequence.
    public func cancel() {
        guard phase != .done else { return }
        toRemote(ZModem.abortSequence)
        fail("cancelled")
    }

    public func feed(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count, phase != .done {
            if phase == .over {
                if let rest = over.feed(Array(bytes[i...])) { finish(rest) }
                return
            }
            if let event = decoder.feed(byte: bytes[i]) { handle(event) }
            i += 1
        }
    }

    /// No "OO" came (some senders don't send it): the session is over anyway.
    public func endWithoutOverAndOut() {
        if phase == .over { finish([]) }
    }

    private func send(_ header: ZModemHeader) {
        lastHeader = header
        toRemote(encoder.hexHeader(header))
    }

    private func handle(_ event: ZModemEvent) {
        switch event {
        case .header(let h):
            switch h.type {
            case .rqinit?:
                if phase == .waiting { start() }
            case .sinit?:
                awaiting = .sinit
            case .file?:
                // A repeated offer (the sender thought it was lost) once a file is under way.
                awaiting = phase == .waiting ? .file : .ignored
            case .data?:
                awaiting = nil
                guard phase == .receiving else { return }
                if h.position == position {
                    resyncing = false
                } else {
                    resyncing = true
                    send(ZModemHeader(type: .rpos, position: position))
                }
            case .eof?:
                guard phase == .receiving, h.position == position else { return }
                onFileEnd?()
                phase = .waiting
                position = 0
                start()
            case .fin?:
                send(ZModemHeader(type: .fin))
                phase = .over
            case .nak?:
                if let lastHeader { send(lastHeader) }
            case .abort?, .ferr?, .can?:
                fail("cancelled by the remote")
            case .command?:
                // A remote command: never run here.
                toRemote(ZModem.abortSequence)
                fail("remote commands are not accepted")
            default:
                break
            }
        case .data(let data, let end):
            switch awaiting {
            case .sinit?:
                awaiting = nil
                send(ZModemHeader(type: .ack))
            case .ignored?:
                awaiting = nil
            case .file?:
                awaiting = nil
                guard let info = ZModemFileInfo(subpacket: data) else {
                    send(ZModemHeader(type: .skip))
                    return
                }
                phase = .offered
                onOffer?(info)
            default:
                guard phase == .receiving, !resyncing else { return }
                onData?(data)
                position &+= UInt32(truncatingIfNeeded: data.count)
                if end == ZModem.crcq || end == ZModem.crcw { send(ZModemHeader(type: .ack, position: position)) }
            }
        case .badCRC:
            if phase == .receiving {
                resyncing = true
                send(ZModemHeader(type: .rpos, position: position))
            } else if awaiting != nil {
                awaiting = nil
                send(ZModemHeader(type: .nak))
            }
        case .cancelled:
            fail("cancelled by the remote")
        }
    }

    private func finish(_ rest: [UInt8]) {
        phase = .done
        onFinished?(rest)
    }

    private func fail(_ reason: String) {
        phase = .done
        onError?(reason)
    }
}

/// A file to send: its offer and a reader for its bytes.
public struct ZModemOutgoingFile {
    public var info: ZModemFileInfo
    public var read: (_ offset: UInt64, _ count: Int) -> [UInt8]

    public init(info: ZModemFileInfo, read: @escaping (UInt64, Int) -> [UInt8]) {
        self.info = info
        self.read = read
    }
}

/// Sending files (the remote runs `rz`): Tabby's send session in `zmodem.ts`. It starts on the
/// receiver's ZRINIT, which the sentry hands over with the first bytes.
public final class ZModemSender {
    public var toRemote: ([UInt8]) -> Void = { _ in }
    /// The receiver took file `index` and the data starts.
    public var onFileStart: ((Int) -> Void)?
    /// Bytes of file `index` sent so far.
    public var onProgress: ((Int, UInt64) -> Void)?
    /// File `index` is done; true when the receiver skipped it.
    public var onFileDone: ((Int, Bool) -> Void)?
    public var onFinished: (([UInt8]) -> Void)?
    public var onError: ((String) -> Void)?
    /// Runs the next batch of data later, so a big file never blocks (tests run them in order).
    public var schedule: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }

    /// Data subpackets of 1 KiB, as lrzsz sends them; 32 KiB per batch.
    public static let blockSize = 1024
    static let batchSize = 32 * 1024

    private enum Phase { case idle, offering, sending, sentEOF, finishing, done }
    private var phase = Phase.idle
    private var files: [ZModemOutgoingFile]
    private var index = 0
    private var started = Set<Int>()
    private var decoder = ZModemDecoder()
    private var encoder = ZModemEncoder()
    private var crc32 = false
    private var offset: UInt64 = 0
    private var generation = 0
    private var lastFrame: [UInt8] = []

    public init(files: [ZModemOutgoingFile]) {
        self.files = files
    }

    public var isActive: Bool { phase != .done }

    public func feed(_ bytes: [UInt8]) {
        var i = 0
        while i < bytes.count, phase != .done {
            let event = decoder.feed(byte: bytes[i])
            i += 1
            if let event { handle(event, rest: Array(bytes[i...])) }
        }
    }

    public func cancel() {
        guard phase != .done else { return }
        toRemote(ZModem.abortSequence)
        fail("cancelled")
    }

    /// Ends the current file early: the receiver keeps what it got.
    public func skipCurrent() {
        guard phase == .sending else { return }
        offset = files[index].info.size ?? offset
    }

    private func handle(_ event: ZModemEvent, rest: [UInt8]) {
        switch event {
        case .header(let h):
            switch h.type {
            case .rinit?:
                crc32 = h.flags & ZModem.canfc32 != 0
                encoder.escapeControls = h.flags & ZModem.escctl != 0
                switch phase {
                case .idle:
                    offerNext()
                case .sending, .sentEOF:
                    generation += 1
                    onFileDone?(index, false)
                    index += 1
                    offerNext()
                case .offering, .finishing:
                    toRemote(lastFrame) // our frame was lost
                case .done:
                    break
                }
            case .rpos?:
                guard [.offering, .sending, .sentEOF].contains(phase), index < files.count else { return }
                if !started.contains(index) {
                    started.insert(index)
                    onFileStart?(index)
                }
                phase = .sending
                offset = UInt64(h.position)
                generation += 1
                toRemote(encoder.binaryHeader(ZModemHeader(type: .data, position: h.position), crc32: crc32))
                stream(generation)
            case .skip?:
                guard [.offering, .sending, .sentEOF].contains(phase) else { return }
                generation += 1
                onFileDone?(index, true)
                index += 1
                offerNext()
            case .nak?:
                if phase == .offering || phase == .finishing { toRemote(lastFrame) }
            case .fin?:
                guard phase == .finishing else { return }
                toRemote(Array("OO".utf8))
                phase = .done
                onFinished?(rest)
            case .abort?, .ferr?, .can?:
                fail("cancelled by the remote")
            default:
                break
            }
        case .cancelled:
            fail("cancelled by the remote")
        case .data, .badCRC:
            break
        }
    }

    private func offerNext() {
        guard index < files.count else {
            phase = .finishing
            lastFrame = encoder.hexHeader(ZModemHeader(type: .fin))
            toRemote(lastFrame)
            return
        }
        phase = .offering
        var info = files[index].info
        info.filesLeft = files.count - index
        info.bytesLeft = files[index...].reduce(0) { $0 + ($1.info.size ?? 0) }
        // ZF0 = ZCBIN: a binary transfer, no newline conversion.
        lastFrame = encoder.binaryHeader(ZModemHeader(type: .file, flags: 0x01), crc32: crc32)
            + encoder.subpacket(info.subpacket, end: ZModem.crcw, crc32: crc32)
        toRemote(lastFrame)
    }

    private func stream(_ run: Int) {
        schedule { [weak self] in
            guard let self, run == self.generation, self.phase == .sending, self.index < self.files.count else { return }
            let file = self.files[self.index]
            let size = file.info.size ?? .max
            var sent = 0
            while sent < Self.batchSize {
                let chunk = self.offset < size ? file.read(self.offset, Self.blockSize) : []
                let last = chunk.count < Self.blockSize || self.offset + UInt64(chunk.count) >= size
                self.toRemote(self.encoder.subpacket(chunk, end: last ? ZModem.crce : ZModem.crcg, crc32: self.crc32))
                self.offset += UInt64(chunk.count)
                sent += chunk.count + 1
                if last {
                    self.toRemote(self.encoder.binaryHeader(ZModemHeader(type: .eof, position: UInt32(truncatingIfNeeded: self.offset)),
                                                            crc32: self.crc32))
                    self.phase = .sentEOF
                    self.onProgress?(self.index, self.offset)
                    return
                }
            }
            self.onProgress?(self.index, self.offset)
            self.stream(run)
        }
    }

    private func fail(_ reason: String) {
        phase = .done
        generation += 1
        onError?(reason)
    }
}

/// Watches a session's output for the start of a ZMODEM session (zmodem.js's `Sentry`): a hex
/// ZRQINIT (the remote runs `sz`: we receive) or ZRINIT (the remote runs `rz`: we send).
/// Everything else goes to the terminal; a header start is held until it is complete or isn't
/// one.
public final class ZModemSentry {
    public enum Detection: Equatable, Sendable { case receive, send }

    public struct Result: Equatable {
        public var toTerminal: [UInt8] = []
        public var detection: Detection?
        /// The header and the rest of the chunk, for the session.
        public var protocolBytes: [UInt8] = []
    }

    private enum Check { case partial, no, header(UInt8) }
    private var held: [UInt8] = []

    public init() {}

    public func feed(_ bytes: [UInt8]) -> Result {
        var result = Result()
        var queue = bytes[...]
        while let c = queue.first {
            queue = queue.dropFirst()
            if held.isEmpty {
                if c == ZModem.zpad { held = [c] } else { result.toTerminal.append(c) }
                continue
            }
            held.append(c)
            switch check(held) {
            case .partial:
                continue
            case .header(let type) where type == ZModemFrameType.rqinit.rawValue || type == ZModemFrameType.rinit.rawValue:
                result.detection = type == ZModemFrameType.rqinit.rawValue ? .receive : .send
                result.protocolBytes = held + queue
                held = []
                return result
            case .header, .no:
                // Not a header: the first byte is text; look again from the next one.
                result.toTerminal.append(held[0])
                queue = held.dropFirst() + queue
                held = []
            }
        }
        return result
    }

    /// Lets a held header start through (nothing more came).
    public func flush() -> [UInt8] {
        defer { held = [] }
        return held
    }

    public var isHolding: Bool { !held.isEmpty }

    private func check(_ b: [UInt8]) -> Check {
        var i = 0
        while i < b.count, i < 2, b[i] == ZModem.zpad { i += 1 }
        guard i < b.count else { return .partial }
        guard b[i] == ZModem.zdle else { return .no }
        i += 1
        guard i < b.count else { return .partial }
        guard b[i] == ZModem.zhex else { return .no }
        i += 1
        let digits = b[i...]
        let values = digits.compactMap(Self.hexValue)
        guard values.count == digits.count else { return .no }
        guard values.count >= 14 else { return .partial }
        let raw = stride(from: 0, to: 14, by: 2).map { values[$0] << 4 | values[$0 + 1] }
        guard ZModemCRC.crc16(Array(raw.prefix(5))) == UInt16(raw[5]) << 8 | UInt16(raw[6]) else { return .no }
        return .header(raw[0])
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        default: return nil
        }
    }
}
