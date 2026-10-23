import Foundation

/// Input mode of a serial or telnet profile (`inputMode`; nil = "Normal", sent as typed).
public enum StreamInputMode: String, CaseIterable, Sendable {
    case localEcho = "local-echo"
    case readline
    case readlineHex = "readline-hex"
}

/// Output mode (`outputMode`; nil = "Normal").
public enum StreamOutputMode: String, CaseIterable, Sendable {
    case hex
}

/// Newline translation (`inputNewlines` / `outputNewlines`; nil = "Keep").
public enum NewlineMode: String, CaseIterable, Sendable {
    case strip, cr, lf, crlf
    case implicitCR = "implicit_cr"
    case implicitLF = "implicit_lf"
}

/// The stream-processing options of a profile (Tabby's `StreamProcessingOptions`).
public struct StreamOptions: Equatable, Sendable {
    public var inputMode: StreamInputMode?
    public var outputMode: StreamOutputMode?
    public var inputNewlines: NewlineMode?
    public var outputNewlines: NewlineMode?

    public init(inputMode: StreamInputMode? = nil, outputMode: StreamOutputMode? = nil,
                inputNewlines: NewlineMode? = nil, outputNewlines: NewlineMode? = nil) {
        self.inputMode = inputMode
        self.outputMode = outputMode
        self.inputNewlines = inputNewlines
        self.outputNewlines = outputNewlines
    }

    /// Reads a profile's `options`; values Tabby doesn't know read as nil.
    public init(_ options: ConfigValue) {
        inputMode = options["inputMode"]?.stringValue.flatMap(StreamInputMode.init(rawValue:))
        outputMode = options["outputMode"]?.stringValue.flatMap(StreamOutputMode.init(rawValue:))
        inputNewlines = options["inputNewlines"]?.stringValue.flatMap(NewlineMode.init(rawValue:))
        outputNewlines = options["outputNewlines"]?.stringValue.flatMap(NewlineMode.init(rawValue:))
    }
}

/// Tabby's `replaceNewlines`. For `strip`/`cr`/`lf`/`crlf`, CRLF and lone CR first become
/// LF; with `carriesCR`, a CR at the end of one chunk pairs with an LF at the start of the
/// next, so a CRLF split across two reads is one newline (Tabby counts it twice).
struct NewlineTranslator {
    let mode: NewlineMode?
    let carriesCR: Bool
    private var afterCR = false

    init(_ mode: NewlineMode?, carriesCR: Bool) {
        self.mode = mode
        self.carriesCR = carriesCR
    }

    mutating func translate(_ data: Data) -> Data {
        guard let mode else { return data }
        var out = Data()
        out.reserveCapacity(data.count + 8)
        switch mode {
        case .implicitCR:
            for b in data {
                if b == 0x0a { out.append(0x0d) }
                out.append(b)
            }
        case .implicitLF:
            for b in data {
                out.append(b)
                if b == 0x0d { out.append(0x0a) }
            }
        case .strip, .cr, .lf, .crlf:
            let replacement: [UInt8] = mode == .strip ? [] : mode == .cr ? [0x0d] : mode == .lf ? [0x0a] : [0x0d, 0x0a]
            if !carriesCR { afterCR = false }
            for b in data {
                if b == 0x0a, afterCR {
                    afterCR = false
                    continue
                }
                afterCR = b == 0x0d
                if b == 0x0d || b == 0x0a {
                    out.append(contentsOf: replacement)
                } else {
                    out.append(b)
                }
            }
        }
        return out
    }
}

/// The hexdump shown in "Hexadecimal" output mode: a dim 4-digit offset, 16 one-byte cells, a
/// dim `｜`, the printable characters, and dim `╳` for cells past the end (design C9). Lines
/// are joined by CRLF.
public enum Hexdump {
    static let dim = "\u{1b}[90m"
    static let undim = "\u{1b}[39m"

    public static func format(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var lines: [String] = []
        var offset = 0
        while offset < bytes.count {
            let row = bytes[offset..<min(offset + 16, bytes.count)]
            var line = dim + hex(offset, width: 4) + ":" + undim
            for b in row { line += " " + hex(Int(b), width: 2) }
            let missing = 16 - row.count
            line += String(repeating: "   ", count: missing)
            line += dim + " ｜ " + undim
            for b in row { line += (0x20...0x7e).contains(b) ? String(UnicodeScalar(b)) : "." }
            if missing > 0 { line += dim + String(repeating: "╳", count: missing) + undim }
            lines.append(line)
            offset += 16
        }
        return lines.joined(separator: "\r\n")
    }

    private static func hex(_ value: Int, width: Int) -> String {
        let s = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }
}

/// Keys → one line at a time, for the "Line by line" and "Hexadecimal" input modes (Tabby
/// uses Node's `readline`). Printable keys go into the line, Backspace/DEL erase a character,
/// ^U and ^C clear the line, Return ends it; escape sequences (arrows…) are dropped.
struct LineEditor {
    enum Event: Equatable {
        case echo(Data)
        case line(String)
        /// The line was cleared (^U, ^C); `interrupted` for ^C.
        case cleared(interrupted: Bool)
    }

    private enum Escape { case none, esc, csi, ss3 }

    private(set) var line = ""
    private var pendingUTF8: [UInt8] = []
    private var escape = Escape.none
    private var lastWasCR = false

    mutating func feed(_ data: Data) -> [Event] {
        var events: [Event] = []
        var echo = Data()
        func flushEcho() {
            if !echo.isEmpty { events.append(.echo(echo)); echo = Data() }
        }
        for b in data {
            let afterCR = lastWasCR
            lastWasCR = false
            switch escape {
            case .esc:
                escape = b == 0x5b ? .csi : b == 0x4f ? .ss3 : .none
                continue
            case .csi:
                if (0x40...0x7e).contains(b) { escape = .none }
                continue
            case .ss3:
                escape = .none
                continue
            case .none:
                break
            }
            switch b {
            case 0x1b:
                escape = .esc
            case 0x0d, 0x0a:
                if b == 0x0a, afterCR { continue }
                lastWasCR = b == 0x0d
                flushEcho()
                events.append(.line(line))
                line = ""
                pendingUTF8 = []
            case 0x7f, 0x08:
                if !line.isEmpty {
                    line.removeLast()
                    echo.append(contentsOf: [0x08, 0x20, 0x08])
                }
            case 0x15, 0x03:
                flushEcho()
                line = ""
                pendingUTF8 = []
                events.append(.cleared(interrupted: b == 0x03))
            case 0x09, 0x20...0x7e:
                line.append(Character(UnicodeScalar(b)))
                echo.append(b)
            case 0x80...:
                pendingUTF8.append(b)
                if let s = String(bytes: pendingUTF8, encoding: .utf8) {
                    line += s
                    echo.append(contentsOf: pendingUTF8)
                    pendingUTF8 = []
                } else if pendingUTF8.count >= 4 {
                    pendingUTF8 = []
                }
            default:
                break
            }
        }
        flushEcho()
        return events
    }
}

/// Tabby's `TerminalStreamProcessor`: what a serial or telnet session's bytes look like on
/// the way to the terminal and back. Pure; the owner calls `outputSettled()` once output has
/// been quiet for 500 ms (when `usesLineEditor`), to draw the prompt again.
public final class StreamProcessor {
    public struct Input: Equatable {
        public var toSession = Data()
        /// Echo, prompts and errors for the terminal.
        public var toTerminal = Data()
    }

    public let options: StreamOptions
    /// Local echo requested by the peer (telnet `DO ECHO`), on top of the input mode.
    public var forceEcho = false
    /// The peer echoes what it gets (telnet `WILL ECHO`): "Local echo" stands aside, or every
    /// key would show twice (Tabby echoes anyway).
    public var peerEchoes = false
    public var usesLineEditor: Bool { options.inputMode == .readline || options.inputMode == .readlineHex }

    private var output: NewlineTranslator
    private var input: NewlineTranslator
    private var echoTranslator = NewlineTranslator(.crlf, carriesCR: false)
    private var editor = LineEditor()
    private var promptVisible = false

    public init(_ options: StreamOptions) {
        self.options = options
        output = NewlineTranslator(options.outputNewlines, carriesCR: true)
        input = NewlineTranslator(options.inputNewlines, carriesCR: false)
    }

    var prompt: String { options.inputMode == .readlineHex ? "hex> " : "> " }

    /// Session output → terminal.
    public func fromSession(_ data: Data) -> Data {
        var out = clearPrompt()
        let translated = output.translate(data)
        if options.outputMode == .hex {
            guard !translated.isEmpty else { return out }
            out.append(Data(("\r\n" + Hexdump.format(translated) + "\r\n\n").utf8))
        } else {
            out.append(translated)
        }
        return out
    }

    /// Keys from the terminal → what to send, and what to show.
    public func fromTerminal(_ data: Data) -> Input {
        var result = Input()
        guard usesLineEditor else {
            if (options.inputMode == .localEcho && !peerEchoes) || forceEcho {
                result.toTerminal = echoTranslator.translate(data)
            }
            result.toSession = input.translate(data)
            return result
        }
        // The line editor echoes by itself, so local echo and the peer's echo request are
        // not applied on top of it (Tabby echoes twice there).
        for event in editor.feed(data) {
            switch event {
            case .echo(let bytes):
                result.toTerminal.append(bytes)
            case .cleared(let interrupted):
                result.toTerminal.append(Data(((interrupted ? "^C" : "") + "\r\n" + prompt).utf8))
                promptVisible = true
            case .line(let text):
                result.toTerminal.append(Data("\r\n".utf8))
                if options.inputMode == .readlineHex {
                    switch Self.decodeHex(text) {
                    case .success(let bytes):
                        result.toSession.append(input.translate(bytes))
                    case .failure(let bad):
                        result.toTerminal.append(ServiceMessage.error("Invalid hex: \(bad.token)"))
                    }
                } else {
                    result.toSession.append(input.translate(Data((text + "\n").utf8)))
                }
                result.toTerminal.append(Data(prompt.utf8))
                promptVisible = true
            }
        }
        return result
    }

    /// Output has been quiet for a while: draw the prompt (and the line so far) again.
    public func outputSettled() -> Data {
        guard usesLineEditor, !promptVisible else { return Data() }
        promptVisible = true
        return Data(("\r\n" + prompt + editor.line).utf8)
    }

    /// Erases a visible prompt, before something else is written to the terminal.
    public func clearPrompt() -> Data {
        guard promptVisible else { return Data() }
        promptVisible = false
        return Data("\u{1b}[2K\r".utf8)
    }

    struct BadHex: Error { var token: String }

    /// Whitespace-separated hex tokens, each with an optional `0x`; an odd digit count gets a
    /// leading 0.
    static func decodeHex(_ text: String) -> Result<Data, BadHex> {
        var out = Data()
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            var token = String(raw)
            if token.lowercased().hasPrefix("0x") { token.removeFirst(2) }
            // ASCII only: full-width digits are hex digits to Character but not to UInt8(radix:).
            guard !token.isEmpty, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                return .failure(BadHex(token: String(raw)))
            }
            if token.count % 2 == 1 { token = "0" + token }
            var index = token.startIndex
            while index < token.endIndex {
                let next = token.index(index, offsetBy: 2)
                guard let byte = UInt8(token[index..<next], radix: 16) else { return .failure(BadHex(token: String(raw))) }
                out.append(byte)
                index = next
            }
        }
        return .success(out)
    }
}
