import Foundation

/// The telnet protocol of Tabby's `TelnetSession` (`tabby-telnet/src/session.ts`), as a pure
/// byte transform: `receive` splits what the peer sent into terminal data and replies.
///
/// Like Tabby, a connection is a raw socket until a chunk starts with IAC; from then on it
/// is telnet, and we offer SGA, TTYPE and NAWS. Tabby's option policy is kept (accept the
/// peer's SGA and ECHO, offer NAWS, TTYPE and ECHO, refuse the rest, `XTERM-256COLOR` as the
/// terminal type). Unlike Tabby, the stream is parsed as a state machine, so commands are
/// found anywhere and across reads, two-byte commands take two bytes, `IAC IAC` is one 0xFF,
/// replies are sent only when an option changes state (no negotiation loops), and 0xFF is
/// escaped in what we send.
public final class TelnetProtocol {
    enum Byte {
        static let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
        static let SB: UInt8 = 250, SE: UInt8 = 240
    }

    enum Option {
        static let echo: UInt8 = 1, suppressGoAhead: UInt8 = 3, terminalType: UInt8 = 24, windowSize: UInt8 = 31
    }

    public struct Result: Equatable {
        public var toTerminal = Data()
        public var toPeer = Data()
        /// Set when the peer turned our local echo on or off.
        public var localEcho: Bool?
    }

    private enum State {
        case data, iac, command(UInt8), subOption, subData(UInt8), subIAC(UInt8)
    }

    /// Telnet mode (false: a raw TCP connection).
    public private(set) var isActive = false
    /// Whether we echo what is typed because the peer asked (`DO ECHO`).
    public var localEcho: Bool { local.contains(Option.echo) }
    public var terminalType = "XTERM-256COLOR"

    private var state = State.data
    private var subBuffer = Data()
    private var size: (cols: Int, rows: Int)?
    /// Options enabled on our side (we WILL) and on the peer's side (they WILL).
    private var local = Set<UInt8>()
    private var remote = Set<UInt8>()
    /// Requests we sent and whose answer must not be answered again.
    private var pendingLocal = Set<UInt8>()
    private var pendingRemote = Set<UInt8>()

    public init() {}

    public func receive(_ data: Data) -> Result {
        var result = Result()
        if !isActive {
            guard data.first == Byte.IAC else {
                result.toTerminal = data
                return result
            }
            isActive = true
            requestRemote(Option.suppressGoAhead, into: &result)
            offerLocal(Option.terminalType, into: &result)
            offerLocal(Option.windowSize, into: &result)
        }
        for byte in data {
            switch state {
            case .data:
                if byte == Byte.IAC { state = .iac } else { result.toTerminal.append(byte) }
            case .iac:
                switch byte {
                case Byte.IAC:
                    result.toTerminal.append(0xff)
                    state = .data
                case Byte.WILL, Byte.WONT, Byte.DO, Byte.DONT:
                    state = .command(byte)
                case Byte.SB:
                    state = .subOption
                default:
                    // NOP, GA, DM, BRK, AYT…: two-byte commands we ignore.
                    state = .data
                }
            case .command(let command):
                handle(command, byte, into: &result)
                state = .data
            case .subOption:
                subBuffer = Data()
                state = .subData(byte)
            case .subData(let option):
                if byte == Byte.IAC { state = .subIAC(option) } else { subBuffer.append(byte) }
            case .subIAC(let option):
                if byte == Byte.IAC {
                    subBuffer.append(0xff)
                    state = .subData(option)
                } else {
                    if byte == Byte.SE { handleSubOption(option, subBuffer, into: &result) }
                    state = .data
                }
            }
        }
        return result
    }

    /// What we send: 0xFF is doubled once the connection speaks telnet.
    public func send(_ data: Data) -> Data {
        guard isActive, data.contains(0xff) else { return data }
        var out = Data()
        out.reserveCapacity(data.count + 4)
        for b in data {
            out.append(b)
            if b == 0xff { out.append(0xff) }
        }
        return out
    }

    /// Records the size and returns the NAWS update to send, once the peer accepted NAWS and
    /// only when the size changed (shells redraw their prompt on every update).
    @discardableResult
    public func resize(cols: Int, rows: Int) -> Data {
        guard cols > 0, rows > 0 else { return Data() }
        let changed = size.map { $0.cols != cols || $0.rows != rows } ?? true
        size = (cols, rows)
        guard changed, isActive, local.contains(Option.windowSize) else { return Data() }
        return windowSize()
    }

    // MARK: Negotiation

    private func handle(_ command: UInt8, _ option: UInt8, into result: inout Result) {
        switch command {
        case Byte.WILL:
            if pendingRemote.remove(option) != nil {
                remote.insert(option)
                remoteEchoChanged(option, on: true, into: &result)
            } else if remote.contains(option) {
                return
            } else if option == Option.suppressGoAhead || option == Option.echo {
                remote.insert(option)
                emit(Byte.DO, option, into: &result)
                remoteEchoChanged(option, on: true, into: &result)
            } else {
                emit(Byte.DONT, option, into: &result)
            }
        case Byte.WONT:
            if pendingRemote.remove(option) != nil {
                remote.remove(option)
            } else if remote.remove(option) != nil {
                emit(Byte.DONT, option, into: &result)
            }
        case Byte.DO:
            if pendingLocal.remove(option) != nil {
                local.insert(option)
                localEnabled(option, into: &result)
            } else if local.contains(option) {
                if option == Option.windowSize { result.toPeer.append(windowSize()) }
            } else if option == Option.echo, remote.contains(Option.echo) {
                // The peer already echoes; two echoes would print every key twice.
                emit(Byte.WONT, option, into: &result)
            } else if [Option.windowSize, Option.terminalType, Option.echo].contains(option) {
                local.insert(option)
                emit(Byte.WILL, option, into: &result)
                localEnabled(option, into: &result)
            } else {
                emit(Byte.WONT, option, into: &result)
            }
        case Byte.DONT:
            if pendingLocal.remove(option) != nil {
                local.remove(option)
            } else if local.remove(option) != nil {
                emit(Byte.WONT, option, into: &result)
                if option == Option.echo { result.localEcho = false }
            }
        default:
            break
        }
    }

    /// The peer started echoing: stop our own echo (Tabby's `telnetRemoteEcho`).
    private func remoteEchoChanged(_ option: UInt8, on: Bool, into result: inout Result) {
        guard option == Option.echo, on, local.contains(Option.echo) else { return }
        local.remove(Option.echo)
        pendingLocal.insert(Option.echo)
        emit(Byte.WONT, Option.echo, into: &result)
        result.localEcho = false
    }

    private func localEnabled(_ option: UInt8, into result: inout Result) {
        if option == Option.windowSize { result.toPeer.append(windowSize()) }
        if option == Option.echo { result.localEcho = true }
    }

    private func handleSubOption(_ option: UInt8, _ value: Data, into result: inout Result) {
        // TTYPE SEND → TTYPE IS <name>
        guard option == Option.terminalType, value.first == 1 else { return }
        result.toPeer.append(subNegotiation(Option.terminalType, Data([0]) + Data(terminalType.utf8)))
    }

    private func requestRemote(_ option: UInt8, into result: inout Result) {
        pendingRemote.insert(option)
        emit(Byte.DO, option, into: &result)
    }

    private func offerLocal(_ option: UInt8, into result: inout Result) {
        pendingLocal.insert(option)
        emit(Byte.WILL, option, into: &result)
    }

    private func emit(_ command: UInt8, _ option: UInt8, into result: inout Result) {
        result.toPeer.append(contentsOf: [Byte.IAC, command, option])
    }

    private func windowSize() -> Data {
        guard let size else { return Data([Byte.IAC, Byte.WONT, Option.windowSize]) }
        let w = min(size.cols, 0xffff), h = min(size.rows, 0xffff)
        return subNegotiation(Option.windowSize, Data([UInt8(w >> 8), UInt8(w & 0xff), UInt8(h >> 8), UInt8(h & 0xff)]))
    }

    private func subNegotiation(_ option: UInt8, _ value: Data) -> Data {
        var out = Data([Byte.IAC, Byte.SB, option])
        for b in value {
            out.append(b)
            if b == Byte.IAC { out.append(b) }
        }
        out.append(contentsOf: [Byte.IAC, Byte.SE])
        return out
    }
}
