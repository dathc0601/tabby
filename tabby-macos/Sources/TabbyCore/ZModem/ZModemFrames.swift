// l10n-ignore-file: protocol bytes and field formats, nothing shown as text.
import Foundation

/// ZMODEM (Chuck Forsberg's protocol as lrzsz speaks it): the constants of the wire format.
public enum ZModem {
    public static let zpad: UInt8 = 0x2A   // '*'
    public static let zdle: UInt8 = 0x18   // CAN
    public static let zbin: UInt8 = 0x41   // 'A': binary header, CRC-16
    public static let zhex: UInt8 = 0x42   // 'B': hex header
    public static let zbin32: UInt8 = 0x43 // 'C': binary header, CRC-32

    // Ends of data subpackets (after ZDLE).
    /// End of frame; a header follows.
    public static let crce: UInt8 = 0x68
    /// More data follows, no reply.
    public static let crcg: UInt8 = 0x69
    /// More data follows; the receiver acknowledges.
    public static let crcq: UInt8 = 0x6A
    /// End of frame; the receiver acknowledges.
    public static let crcw: UInt8 = 0x6B
    static let rub0: UInt8 = 0x6C // 0x7F
    static let rub1: UInt8 = 0x6D // 0xFF

    // ZRINIT capabilities (ZF0).
    public static let canfdx: UInt8 = 0x01
    public static let canovio: UInt8 = 0x02
    public static let canfc32: UInt8 = 0x20
    public static let escctl: UInt8 = 0x40

    /// lrzsz's `canit`: ten CANs, then ten backspaces to erase them on a terminal.
    public static let abortSequence: [UInt8] = Array(repeating: 0x18, count: 10) + Array(repeating: 0x08, count: 10)
}

public enum ZModemFrameType: UInt8, Sendable {
    case rqinit = 0, rinit, sinit, ack, file, skip, nak, abort, fin, rpos, data, eof, ferr, crc, challenge, compl, can, freecnt, command, stderr
}

/// A header: a type and four bytes (a little-endian position, or flags with ZF0 last).
public struct ZModemHeader: Equatable, Sendable {
    public var rawType: UInt8
    public var bytes: [UInt8]

    public var type: ZModemFrameType? { ZModemFrameType(rawValue: rawType) }

    public init(rawType: UInt8, bytes: [UInt8]) {
        self.rawType = rawType
        self.bytes = bytes.count == 4 ? bytes : Array((bytes + [0, 0, 0, 0]).prefix(4))
    }

    public init(type: ZModemFrameType, position: UInt32 = 0) {
        self.init(rawType: type.rawValue, bytes: [UInt8(position & 0xFF), UInt8((position >> 8) & 0xFF),
                                                  UInt8((position >> 16) & 0xFF), UInt8(position >> 24)])
    }

    /// A header whose ZF0 flags byte (the last one) is `flags`.
    public init(type: ZModemFrameType, flags: UInt8) {
        self.init(rawType: type.rawValue, bytes: [0, 0, 0, flags])
    }

    public var position: UInt32 {
        UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    public var flags: UInt8 { bytes[3] }
}

public enum ZModemCRC {
    /// CRC-16/XMODEM (polynomial 0x1021, initial value 0).
    public static func crc16(_ data: [UInt8], _ seed: UInt16 = 0) -> UInt16 {
        var crc = seed
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc << 1) ^ 0x1021 : crc << 1 }
        }
        return crc
    }

    private static let table32: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// CRC-32 (IEEE), as ZBIN32 frames use it.
    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table32[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return ~crc
    }
}

/// Writes ZMODEM frames, escaping as lrzsz's `zsendline` does.
public struct ZModemEncoder {
    /// The receiver asked for every control character to be escaped (ESCCTL).
    public var escapeControls = false
    private var lastSent: UInt8 = 0

    public init() {}

    public mutating func escape(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 8)
        for c in data {
            switch c {
            case 0x18, 0x10, 0x11, 0x13, 0x90, 0x91, 0x93:
                out += [ZModem.zdle, c ^ 0x40]
                lastSent = c ^ 0x40
            case 0x0D where escapeControls || lastSent & 0x7F == 0x40, 0x8D where escapeControls || lastSent & 0x7F == 0x40:
                out += [ZModem.zdle, c ^ 0x40]
                lastSent = c ^ 0x40
            case 0x7F where escapeControls:
                out += [ZModem.zdle, ZModem.rub0]
                lastSent = ZModem.rub0
            case 0xFF where escapeControls:
                out += [ZModem.zdle, ZModem.rub1]
                lastSent = ZModem.rub1
            default:
                if escapeControls && c & 0x60 == 0 {
                    out += [ZModem.zdle, c ^ 0x40]
                    lastSent = c ^ 0x40
                } else {
                    out.append(c)
                    lastSent = c
                }
            }
        }
        return out
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    private static func hex(_ byte: UInt8) -> [UInt8] { [hexDigits[Int(byte >> 4)], hexDigits[Int(byte & 0x0F)]] }

    /// `** ZDLE B` + type, four bytes and CRC-16 in hex, CR LF (with the high bit), and XON
    /// except after ZACK and ZFIN.
    public func hexHeader(_ header: ZModemHeader) -> [UInt8] {
        let body = [header.rawType] + header.bytes
        let crc = ZModemCRC.crc16(body)
        var out: [UInt8] = [ZModem.zpad, ZModem.zpad, ZModem.zdle, ZModem.zhex]
        for b in body + [UInt8(crc >> 8), UInt8(crc & 0xFF)] { out += Self.hex(b) }
        out += [0x0D, 0x8A]
        if header.type != .ack && header.type != .fin { out.append(0x11) }
        return out
    }

    public mutating func binaryHeader(_ header: ZModemHeader, crc32: Bool) -> [UInt8] {
        let body = [header.rawType] + header.bytes
        var out: [UInt8] = [ZModem.zpad, ZModem.zdle, crc32 ? ZModem.zbin32 : ZModem.zbin]
        if crc32 {
            let crc = ZModemCRC.crc32(body)
            out += escape(body + [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)])
        } else {
            let crc = ZModemCRC.crc16(body)
            out += escape(body + [UInt8(crc >> 8), UInt8(crc & 0xFF)])
        }
        return out
    }

    /// Data, then ZDLE + `end`, then the CRC of the data and `end`.
    public mutating func subpacket(_ data: [UInt8], end: UInt8, crc32: Bool) -> [UInt8] {
        var out = escape(data)
        out += [ZModem.zdle, end]
        lastSent = end
        if crc32 {
            let crc = ZModemCRC.crc32(data + [end])
            out += escape([UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)])
        } else {
            let crc = ZModemCRC.crc16(data + [end])
            out += escape([UInt8(crc >> 8), UInt8(crc & 0xFF)])
        }
        if end == ZModem.crcw { out.append(0x11) } // lrzsz sends XON after a ZCRCW subpacket
        return out
    }
}

public enum ZModemEvent: Equatable, Sendable {
    case header(ZModemHeader)
    case data([UInt8], end: UInt8)
    /// A header or subpacket with a bad CRC (or garbled); the decoder looks for the next header.
    case badCRC
    /// Five CANs in a row: the other side gave up.
    case cancelled
}

/// Reads ZMODEM frames from a byte stream, a chunk at a time (lrzsz's `zgethdr`/`zrdata`).
public struct ZModemDecoder {
    private enum State {
        case seeking
        case afterPad(pads: Int)
        case afterZDLE
        case hex([UInt8])
        case hexEnd
        case binary(crc32: Bool, [UInt8])
        case data(crc32: Bool, [UInt8])
        case dataCRC(crc32: Bool, [UInt8], end: UInt8, crc: [UInt8])
    }

    private var state = State.seeking
    private var escaped = false
    private var cans = 0
    /// Inside a run of CANs that was already reported.
    private var cancelReported = false
    /// Whether the last header's data subpackets use CRC-32.
    private var subpacketsCRC32 = false
    static let maxSubpacket = 32 * 1024

    public init() {}

    /// Types whose header is followed by data subpackets.
    static func carriesData(_ type: UInt8) -> Bool {
        [ZModemFrameType.sinit, .file, .data, .command].map(\.rawValue).contains(type)
    }

    public mutating func feed(_ bytes: [UInt8]) -> [ZModemEvent] {
        var events: [ZModemEvent] = []
        for byte in bytes {
            if let event = take(byte) { events.append(event) }
        }
        return events
    }

    /// Resynchronises: the next bytes are searched for a header.
    public mutating func seekHeader() {
        state = .seeking
        escaped = false
    }

    private mutating func take(_ c: UInt8) -> ZModemEvent? {
        if c == ZModem.zdle {
            cans += 1
            if cans >= 5 {
                seekHeader()
                if cancelReported { return nil }
                cancelReported = true
                return .cancelled
            }
        } else {
            cans = 0
            cancelReported = false
        }
        switch state {
        case .seeking:
            if c == ZModem.zpad { state = .afterPad(pads: 1) }
        case .afterPad(let pads):
            if c == ZModem.zpad && pads < 2 { state = .afterPad(pads: pads + 1) }
            else if c == ZModem.zdle { state = .afterZDLE }
            else if c == ZModem.zpad { state = .afterPad(pads: pads) }
            else { state = .seeking }
        case .afterZDLE:
            switch c {
            case ZModem.zhex: state = .hex([])
            case ZModem.zbin: state = .binary(crc32: false, [])
            case ZModem.zbin32: state = .binary(crc32: true, [])
            default: state = .seeking
            }
        case .hex(var digits):
            guard let v = Self.hexValue(c) else {
                state = .seeking
                return .badCRC
            }
            digits.append(v)
            if digits.count < 14 {
                state = .hex(digits)
                return nil
            }
            let raw = stride(from: 0, to: 14, by: 2).map { digits[$0] << 4 | digits[$0 + 1] }
            state = .hexEnd
            return header(raw, crc32: false, binary: false)
        case .hexEnd:
            // CR, LF (maybe with the high bit) and XON follow; ZPAD starts the next frame.
            if c == ZModem.zpad { state = .afterPad(pads: 1) }
            else if ![0x0D, 0x8D, 0x0A, 0x8A, 0x11].contains(c) { state = .seeking; return take(c) }
        case .binary(let crc32, var body):
            guard let (byte, end) = unescape(c) else { return nil }
            if end != nil {
                state = .seeking
                return .badCRC
            }
            body.append(byte)
            if body.count < (crc32 ? 9 : 7) {
                state = .binary(crc32: crc32, body)
                return nil
            }
            state = .seeking
            return header(body, crc32: crc32, binary: true)
        case .data(let crc32, var data):
            guard let (byte, end) = unescape(c) else { return nil }
            if let end {
                state = .dataCRC(crc32: crc32, data, end: end, crc: [])
                return nil
            }
            data.append(byte)
            if data.count > Self.maxSubpacket {
                state = .seeking
                return .badCRC
            }
            state = .data(crc32: crc32, data)
        case .dataCRC(let crc32, let data, let end, var crc):
            guard let (byte, marker) = unescape(c) else { return nil }
            if marker != nil {
                state = .seeking
                return .badCRC
            }
            crc.append(byte)
            if crc.count < (crc32 ? 4 : 2) {
                state = .dataCRC(crc32: crc32, data, end: end, crc: crc)
                return nil
            }
            let good: Bool
            if crc32 {
                let value = UInt32(crc[0]) | UInt32(crc[1]) << 8 | UInt32(crc[2]) << 16 | UInt32(crc[3]) << 24
                good = ZModemCRC.crc32(data + [end]) == value
            } else {
                good = ZModemCRC.crc16(data + [end]) == UInt16(crc[0]) << 8 | UInt16(crc[1])
            }
            guard good else {
                state = .seeking
                return .badCRC
            }
            state = end == ZModem.crcg || end == ZModem.crcq ? .data(crc32: crc32, []) : .seeking
            return .data(data, end: end)
        }
        return nil
    }

    /// The byte after ZDLE escaping (nil while it is half read); `end` is set for a subpacket end.
    private mutating func unescape(_ c: UInt8) -> (UInt8, UInt8?)? {
        if escaped {
            escaped = false
            switch c {
            case ZModem.crce, ZModem.crcg, ZModem.crcq, ZModem.crcw: return (0, c)
            case ZModem.rub0: return (0x7F, nil)
            case ZModem.rub1: return (0xFF, nil)
            case ZModem.zdle: escaped = true; return nil
            default: return c & 0x60 == 0x40 ? (c ^ 0x40, nil) : (c, nil)
            }
        }
        switch c {
        case ZModem.zdle: escaped = true; return nil
        case 0x11, 0x13, 0x91, 0x93: return nil // flow control noise
        default: return (c, nil)
        }
    }

    private mutating func header(_ raw: [UInt8], crc32: Bool, binary: Bool) -> ZModemEvent {
        let body = Array(raw.prefix(5))
        let good: Bool
        if crc32 {
            let value = UInt32(raw[5]) | UInt32(raw[6]) << 8 | UInt32(raw[7]) << 16 | UInt32(raw[8]) << 24
            good = ZModemCRC.crc32(body) == value
        } else {
            good = ZModemCRC.crc16(body) == UInt16(raw[5]) << 8 | UInt16(raw[6])
        }
        guard good else {
            state = .seeking
            return .badCRC
        }
        let header = ZModemHeader(rawType: body[0], bytes: Array(body[1...]))
        if binary && Self.carriesData(header.rawType) {
            subpacketsCRC32 = crc32
            state = .data(crc32: crc32, [])
        }
        return .header(header)
    }

    private static func hexValue(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x61 + 10
        case 0x41...0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

/// A ZFILE offer: `name NUL size mtime mode serial files-left bytes-left NUL` (size decimal,
/// mtime and mode octal).
public struct ZModemFileInfo: Equatable, Sendable {
    public var name: String
    public var size: UInt64?
    public var mtime: Date?
    public var mode: UInt32?
    public var filesLeft: Int = 1
    public var bytesLeft: UInt64?

    public init(name: String, size: UInt64?, mtime: Date?, mode: UInt32?, filesLeft: Int = 1, bytesLeft: UInt64? = nil) {
        self.name = name
        self.size = size
        self.mtime = mtime
        self.mode = mode
        self.filesLeft = filesLeft
        self.bytesLeft = bytesLeft
    }

    /// Reads an offer; the name loses any folders (a remote must not pick where files land).
    public init?(subpacket: [UInt8]) {
        let parts = subpacket.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawName = parts.first.map({ String(decoding: $0, as: UTF8.self) }) else { return nil }
        let name = rawName.split(separator: "/").last.map(String.init) ?? ""
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        self.name = name
        let fields = parts.count > 1
            ? String(decoding: parts[1].prefix { $0 != 0 }, as: UTF8.self).split(separator: " ").map(String.init) : []
        size = fields.count > 0 ? UInt64(fields[0]) : nil
        mtime = fields.count > 1 ? UInt64(fields[1], radix: 8).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } : nil
        mode = fields.count > 2 ? UInt32(fields[2], radix: 8).flatMap { $0 > 0 ? $0 : nil } : nil
        filesLeft = fields.count > 4 ? Int(fields[4]) ?? 1 : 1
        bytesLeft = fields.count > 5 ? UInt64(fields[5]) : nil
    }

    public var subpacket: [UInt8] {
        let mtimeOctal = String(UInt64(max(0, mtime?.timeIntervalSince1970 ?? 0)), radix: 8)
        let modeOctal = String(mode ?? 0, radix: 8)
        let tail = "\(size ?? 0) \(mtimeOctal) \(modeOctal) 0 \(filesLeft) \(bytesLeft ?? size ?? 0)"
        return Array(name.utf8) + [0] + Array(tail.utf8) + [0]
    }
}
