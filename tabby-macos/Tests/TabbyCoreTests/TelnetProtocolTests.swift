import XCTest
@testable import TabbyCore

/// The telnet side of Tabby's `TelnetSession` (`tabby-telnet/src/session.ts`), with the
/// stream parsed as a state machine (Tabby only reads IAC at the start of a chunk).
final class TelnetProtocolTests: XCTestCase {
    let IAC: UInt8 = 255, DONT: UInt8 = 254, DO: UInt8 = 253, WONT: UInt8 = 252, WILL: UInt8 = 251
    let SB: UInt8 = 250, SE: UInt8 = 240, GA: UInt8 = 249, NOP: UInt8 = 241
    let ECHO: UInt8 = 1, SGA: UInt8 = 3, TTYPE: UInt8 = 24, NAWS: UInt8 = 31, LINEMODE: UInt8 = 34

    private func started(cols: Int = 80, rows: Int = 24) -> TelnetProtocol {
        let p = TelnetProtocol()
        p.resize(cols: cols, rows: rows)
        _ = p.receive(Data([IAC, NOP]))
        return p
    }

    func testRawDataPassesUntouchedUntilTheFirstIAC() {
        let p = TelnetProtocol()
        let r = p.receive(Data("hello \u{ff}".utf8))
        XCTAssertFalse(p.isActive, "telnet starts only when a chunk starts with IAC")
        XCTAssertEqual(r.toTerminal, Data("hello \u{ff}".utf8))
        XCTAssertTrue(r.toPeer.isEmpty)
        XCTAssertEqual(p.send(Data([0xff])), Data([0xff]), "raw sockets send 0xFF as is")
    }

    func testABannerBeforeNegotiationStillTurnsTelnetOn() {
        let p = TelnetProtocol()
        _ = p.receive(Data("Welcome\r\n".utf8))
        XCTAssertFalse(p.isActive)
        let r = p.receive(Data([IAC, DO, TTYPE]))
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(r.toPeer, Data([IAC, DO, SGA, IAC, WILL, TTYPE, IAC, WILL, NAWS]), "already offered TTYPE: no second WILL")
    }

    func testStartingTelnetOffersTabbysOptions() {
        let p = TelnetProtocol()
        let r = p.receive(Data([IAC, WILL, ECHO]) + Data("login: ".utf8))
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(r.toPeer, Data([IAC, DO, SGA, IAC, WILL, TTYPE, IAC, WILL, NAWS, IAC, DO, ECHO]))
        XCTAssertEqual(r.toTerminal, Data("login: ".utf8))
    }

    func testAnswersToOptionsWeAskedForGetNoReply() {
        let p = started()
        XCTAssertTrue(p.receive(Data([IAC, WILL, SGA])).toPeer.isEmpty)
    }

    func testUnknownOptionsAreRefused() {
        let p = started()
        XCTAssertEqual(p.receive(Data([IAC, WILL, LINEMODE])).toPeer, Data([IAC, DONT, LINEMODE]))
        XCTAssertEqual(p.receive(Data([IAC, DO, LINEMODE])).toPeer, Data([IAC, WONT, LINEMODE]))
        XCTAssertTrue(p.receive(Data([IAC, DONT, LINEMODE])).toPeer.isEmpty, "already off: no reply, no loop")
        XCTAssertTrue(p.receive(Data([IAC, WONT, LINEMODE])).toPeer.isEmpty)
    }

    func testWindowSizeIsSentWhenAskedAndOnResize() {
        let p = started(cols: 120, rows: 40)
        let r = p.receive(Data([IAC, DO, NAWS]))
        XCTAssertEqual(r.toPeer, Data([IAC, SB, NAWS, 0, 120, 0, 40, IAC, SE]), "WILL NAWS was offered already")
        XCTAssertEqual(p.resize(cols: 255, rows: 300), Data([IAC, SB, NAWS, 0, 255, 255, 1, 44, IAC, SE]),
                       "0xFF inside the size is doubled")
    }

    // Found in M9: busybox's shell redraws its prompt on every NAWS, so the pane's repeated
    // resize to the same size printed extra prompts.
    func testAnUnchangedSizeIsNotSentAgain() {
        let p = started(cols: 80, rows: 24)
        _ = p.receive(Data([IAC, DO, NAWS]))
        XCTAssertTrue(p.resize(cols: 80, rows: 24).isEmpty)
        XCTAssertEqual(p.resize(cols: 81, rows: 24), Data([IAC, SB, NAWS, 0, 81, 0, 24, IAC, SE]))
    }

    func testResizeSendsNothingBeforeTheServerWantsTheSize() {
        let p = started()
        XCTAssertTrue(p.resize(cols: 100, rows: 30).isEmpty)
        XCTAssertTrue(TelnetProtocol().resize(cols: 100, rows: 30).isEmpty, "nor on a raw socket")
    }

    func testTerminalTypeIsXterm256Color() {
        let p = started()
        XCTAssertTrue(p.receive(Data([IAC, DO, TTYPE])).toPeer.isEmpty)
        let r = p.receive(Data([IAC, SB, TTYPE, 1, IAC, SE]))
        XCTAssertEqual(r.toPeer, Data([IAC, SB, TTYPE, 0]) + Data("XTERM-256COLOR".utf8) + Data([IAC, SE]))
    }

    func testTheServerAskingUsToEchoTurnsLocalEchoOn() {
        let p = started()
        let r = p.receive(Data([IAC, DO, ECHO]))
        XCTAssertEqual(r.toPeer, Data([IAC, WILL, ECHO]))
        XCTAssertEqual(r.localEcho, true)
        XCTAssertTrue(p.localEcho)
        let off = p.receive(Data([IAC, DONT, ECHO]))
        XCTAssertEqual(off.toPeer, Data([IAC, WONT, ECHO]))
        XCTAssertEqual(off.localEcho, false)
    }

    func testTheServerEchoingTurnsOurEchoOff() {
        let p = started()
        _ = p.receive(Data([IAC, DO, ECHO]))
        let r = p.receive(Data([IAC, WILL, ECHO]))
        XCTAssertEqual(r.toPeer, Data([IAC, DO, ECHO, IAC, WONT, ECHO]))
        XCTAssertEqual(r.localEcho, false)
        XCTAssertTrue(p.receive(Data([IAC, DONT, ECHO])).toPeer.isEmpty, "the answer to our WONT")
        XCTAssertEqual(p.receive(Data([IAC, DO, ECHO])).toPeer, Data([IAC, WONT, ECHO]),
                       "while the server echoes, we don't")
    }

    func testCommandsAnywhereInTheStreamAreRemoved() {
        let p = started()
        let r = p.receive(Data("ab".utf8) + Data([IAC, GA]) + Data("cd".utf8) + Data([IAC, WILL, LINEMODE]) + Data("ef".utf8))
        XCTAssertEqual(r.toTerminal, Data("abcdef".utf8), "two-byte commands take two bytes")
        XCTAssertEqual(r.toPeer, Data([IAC, DONT, LINEMODE]))
    }

    func testACommandSplitAcrossReadsIsStillACommand() {
        let p = started()
        XCTAssertEqual(p.receive(Data("x".utf8) + Data([IAC])).toTerminal, Data("x".utf8))
        let r = p.receive(Data([DO, LINEMODE]) + Data("y".utf8))
        XCTAssertEqual(r.toTerminal, Data("y".utf8))
        XCTAssertEqual(r.toPeer, Data([IAC, WONT, LINEMODE]))
        _ = p.receive(Data([IAC, SB, TTYPE]))
        XCTAssertEqual(p.receive(Data([1, IAC, SE])).toPeer.prefix(4), Data([IAC, SB, TTYPE, 0]))
    }

    func testAnEscapedFFReachesTheTerminalOnce() {
        let p = started()
        XCTAssertEqual(p.receive(Data([0x41, IAC, IAC, 0x42])).toTerminal, Data([0x41, 0xff, 0x42]))
    }

    func testOutgoingFFIsDoubledInTelnetMode() {
        let p = started()
        XCTAssertEqual(p.send(Data([0x41, 0xff])), Data([0x41, 0xff, 0xff]))
    }
}
