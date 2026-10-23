import XCTest
@testable import TabbyCore

/// Tabby's `TerminalStreamProcessor` (`tabby-terminal/src/middleware/streamProcessing.ts`):
/// input and output modes and newline translation for serial and telnet sessions.
final class StreamProcessorTests: XCTestCase {
    private func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
    private func data(_ s: String) -> Data { Data(s.utf8) }

    private func processor(input: String? = nil, output: String? = nil,
                           inputNewlines: String? = nil, outputNewlines: String? = nil) -> StreamProcessor {
        var o: [String: ConfigValue] = [:]
        if let input { o["inputMode"] = .string(input) }
        if let output { o["outputMode"] = .string(output) }
        if let inputNewlines { o["inputNewlines"] = .string(inputNewlines) }
        if let outputNewlines { o["outputNewlines"] = .string(outputNewlines) }
        return StreamProcessor(StreamOptions(.object(o)))
    }

    // MARK: Options

    func testOptionsReadTabbysKeysAndIgnoreUnknownValues() {
        let o = StreamOptions(["inputMode": "readline-hex", "outputMode": "hex",
                               "inputNewlines": "implicit_cr", "outputNewlines": "nonsense"])
        XCTAssertEqual(o.inputMode, .readlineHex)
        XCTAssertEqual(o.outputMode, .hex)
        XCTAssertEqual(o.inputNewlines, .implicitCR)
        XCTAssertNil(o.outputNewlines)
        XCTAssertEqual(StreamOptions(["inputMode": nil]).inputMode, nil)
    }

    // MARK: Newlines

    func testNewlineModesFollowTabbysTable() {
        let sample = "a\r\nb\rc\nd"
        let expected: [(String?, String)] = [
            (nil, "a\r\nb\rc\nd"),
            ("implicit_cr", "a\r\r\nb\rc\r\nd"),
            ("implicit_lf", "a\r\n\nb\r\nc\nd"),
            ("strip", "abcd"),
            ("cr", "a\rb\rc\rd"),
            ("lf", "a\nb\nc\nd"),
            ("crlf", "a\r\nb\r\nc\r\nd"),
        ]
        for (mode, result) in expected {
            let p = processor(outputNewlines: mode)
            XCTAssertEqual(text(p.fromSession(data(sample))), result, "outputNewlines \(mode ?? "nil")")
        }
    }

    func testACRLFSplitAcrossTwoReadsIsOneNewline() {
        let p = processor(outputNewlines: "crlf")
        XCTAssertEqual(text(p.fromSession(data("a\r"))), "a\r\n")
        XCTAssertEqual(text(p.fromSession(data("\nb"))), "b")
        XCTAssertEqual(text(p.fromSession(data("\nc"))), "\r\nc", "a lone LF later is still a newline")
    }

    func testInputNewlinesApplyToWhatIsSent() {
        let p = processor(inputNewlines: "crlf")
        XCTAssertEqual(text(p.fromTerminal(data("ls\r")).toSession), "ls\r\n")
    }

    // MARK: Input modes

    func testNormalModeSendsKeysAsTypedWithoutEcho() {
        let p = processor()
        let out = p.fromTerminal(data("ab\r"))
        XCTAssertEqual(text(out.toSession), "ab\r")
        XCTAssertTrue(out.toTerminal.isEmpty)
    }

    func testLocalEchoShowsKeysWithCRLF() {
        let p = processor(input: "local-echo")
        let out = p.fromTerminal(data("ab\r"))
        XCTAssertEqual(text(out.toSession), "ab\r")
        XCTAssertEqual(text(out.toTerminal), "ab\r\n")
    }

    func testLocalEchoStandsAsideWhileThePeerEchoes() {
        let p = processor(input: "local-echo")
        p.peerEchoes = true
        XCTAssertTrue(p.fromTerminal(data("a")).toTerminal.isEmpty)
        p.peerEchoes = false
        XCTAssertEqual(text(p.fromTerminal(data("b")).toTerminal), "b")
    }

    func testForcedEchoWorksInNormalMode() {
        let p = processor()
        p.forceEcho = true
        XCTAssertEqual(text(p.fromTerminal(data("x")).toTerminal), "x")
    }

    func testLineByLineSendsTheLineOnReturn() {
        let p = processor(input: "readline")
        let typed = p.fromTerminal(data("ab"))
        XCTAssertTrue(typed.toSession.isEmpty, "nothing leaves before Return")
        XCTAssertEqual(text(typed.toTerminal), "ab")
        let sent = p.fromTerminal(data("\r"))
        XCTAssertEqual(text(sent.toSession), "ab\n")
        XCTAssertEqual(text(sent.toTerminal), "\r\n> ")
    }

    func testLineByLineEditingKeys() {
        let p = processor(input: "readline")
        var out = p.fromTerminal(data("abc\u{7f}"))
        XCTAssertEqual(text(out.toTerminal), "abc\u{8} \u{8}")
        out = p.fromTerminal(data("\u{8}x\r"))
        XCTAssertEqual(text(out.toSession), "ax\n", "Backspace (^H) erases too")

        _ = p.fromTerminal(data("junk\u{15}"))   // ^U
        XCTAssertEqual(text(p.fromTerminal(data("ok\r")).toSession), "ok\n")

        _ = p.fromTerminal(data("junk\u{03}"))   // ^C clears and keeps the editor working
        XCTAssertEqual(text(p.fromTerminal(data("go\r")).toSession), "go\n")

        let arrows = p.fromTerminal(data("\u{1b}[A\u{1b}[Dz\r"))
        XCTAssertEqual(text(arrows.toSession), "z\n", "escape sequences are not part of the line")
    }

    func testLineByLineErasesWholeCharacters() {
        let p = processor(input: "readline")
        _ = p.fromTerminal(data("é"))
        _ = p.fromTerminal(Data([0x7f]))
        XCTAssertEqual(text(p.fromTerminal(data("e\r")).toSession), "e\n")
    }

    func testAPastedCRLFSendsOneLine() {
        let p = processor(input: "readline")
        let out = p.fromTerminal(data("one\r\ntwo\r\n"))
        XCTAssertEqual(text(out.toSession), "one\ntwo\n")
    }

    func testThePromptClearsForOutputAndComesBackWhenItSettles() {
        let p = processor(input: "readline")
        XCTAssertEqual(text(p.outputSettled()), "\r\n> ", "the first prompt appears once things are quiet")
        XCTAssertEqual(text(p.fromSession(data("hello"))), "\u{1b}[2K\rhello")
        _ = p.fromTerminal(data("ab"))
        XCTAssertEqual(text(p.outputSettled()), "\r\n> ab", "the line typed so far is drawn again")
        XCTAssertEqual(text(p.outputSettled()), "", "nothing to redraw while the prompt shows")
        XCTAssertEqual(text(p.fromSession(data("x"))), "\u{1b}[2K\rx")
    }

    func testNormalModeHasNoPrompt() {
        let p = processor()
        XCTAssertEqual(text(p.outputSettled()), "")
        XCTAssertFalse(p.usesLineEditor)
    }

    func testHexInputSendsTheBytesTyped() {
        let p = processor(input: "readline-hex")
        XCTAssertEqual(text(p.outputSettled()), "\r\nhex> ")
        let out = p.fromTerminal(data("0x41 42  0a\r"))
        XCTAssertEqual(out.toSession, Data([0x41, 0x42, 0x0a]))
        XCTAssertEqual(p.fromTerminal(data("0d0a\r")).toSession, Data([0x0d, 0x0a]))
        XCTAssertEqual(p.fromTerminal(data("a\r")).toSession, Data([0x0a]), "an odd digit count gets a leading 0")
    }

    func testHexInputRejectsALineWithABadToken() {
        let p = processor(input: "readline-hex")
        let out = p.fromTerminal(data("41 zz\r"))
        XCTAssertTrue(out.toSession.isEmpty)
        XCTAssertTrue(text(out.toTerminal).contains("Invalid hex: zz"))
    }

    // Review: Character.isHexDigit is true for full-width digits (an IME in full-width mode),
    // which UInt8(_, radix: 16) can't parse: the app crashed.
    func testFullWidthDigitsAreABadTokenNotACrash() {
        let p = processor(input: "readline-hex")
        let out = p.fromTerminal(data("１Ａ\r"))
        XCTAssertTrue(out.toSession.isEmpty)
        XCTAssertTrue(text(out.toTerminal).contains("Invalid hex: １Ａ"))
    }

    func testHexInputAppliesInputNewlinesToTheBytes() {
        let p = processor(input: "readline-hex", inputNewlines: "crlf")
        XCTAssertEqual(p.fromTerminal(data("0d\r")).toSession, Data([0x0d, 0x0a]))
    }

    // MARK: Output modes

    func testHexOutputDumpsEachChunk() {
        let p = processor(output: "hex")
        let dim = "\u{1b}[90m", undim = "\u{1b}[39m"
        let empty = "   "
        // Design C9: the offset, the gutter and the empty cells are bright black.
        let line = dim + "0000:" + undim + " 48 69 0a" + String(repeating: empty, count: 13) + dim + " ｜ " + undim
            + "Hi." + dim + String(repeating: "╳", count: 13) + undim
        XCTAssertEqual(text(p.fromSession(data("Hi\n"))), "\r\n" + line + "\r\n\n")
    }

    func testHexdumpStartsANewLineEvery16Bytes() {
        let dump = Hexdump.format(Data(0..<17))
        let lines = dump.components(separatedBy: "\r\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("\u{1b}[90m0000:\u{1b}[39m 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f"))
        XCTAssertTrue(lines[1].hasPrefix("\u{1b}[90m0010:\u{1b}[39m 10   "))
    }

    func testHexOutputIsTranslatedFirst() {
        let p = processor(output: "hex", outputNewlines: "crlf")
        XCTAssertTrue(text(p.fromSession(data("\n"))).hasPrefix("\r\n\u{1b}[90m0000:\u{1b}[39m 0d 0a "))
    }

    // MARK: Interrupting the prompt

    func testAServiceMessageClearsAVisiblePromptFirst() {
        let p = processor(input: "readline")
        _ = p.outputSettled()
        XCTAssertEqual(text(p.clearPrompt()), "\u{1b}[2K\r")
        XCTAssertEqual(text(p.clearPrompt()), "", "once")
    }
}

final class ServiceMessageTests: XCTestCase {
    func testBadgesUseTabbysColours() {
        XCTAssertEqual(String(decoding: ServiceMessage.line("Port opened", badge: .serial), as: UTF8.self),
                       "\u{1b}[0;30;47m Serial \u{1b}[0m Port opened\r\n")
        XCTAssertEqual(String(decoding: ServiceMessage.line("Connected", badge: .telnet), as: UTF8.self),
                       "\u{1b}[0;30;47m Telnet \u{1b}[0m Connected\r\n")
        XCTAssertEqual(String(decoding: ServiceMessage.line("a\nb", badge: .ssh), as: UTF8.self),
                       "\u{1b}[0;30;46m SSH \u{1b}[0m a\r\n      b\r\n", "continuation lines line up after the badge")
    }

    /// Design C9 and Tabby's sessions (`colors.bgRed.black(' X ')`): a black X on red, then
    /// the message in the terminal's own colour.
    func testErrorsGetTheRedX() {
        XCTAssertEqual(String(decoding: ServiceMessage.error("Port is busy"), as: UTF8.self),
                       "\u{1b}[0;30;41m X \u{1b}[0m Port is busy\r\n")
    }
}
