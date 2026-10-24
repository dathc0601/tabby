import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 6: a pane runs its session's output through the ZMODEM bridge.
final class ZModemPaneTests: XCTestCase {
    final class Host: ZModemHost {
        var asked: [ZModemDirection] = []
        var answer = false
        func zmodemAsk(_ direction: ZModemDirection, in pane: TerminalPane, answer: @escaping (Bool) -> Void) {
            asked.append(direction)
            answer(self.answer)
        }
        func zmodemSave(_ info: ZModemFileInfo, in pane: TerminalPane, answer: @escaping (ZModemFileSink?) -> Void) { answer(nil) }
        func zmodemChooseFiles(in pane: TerminalPane, answer: @escaping ([ZModemUpload]) -> Void) { answer([]) }
    }

    func testAPaneAsksItsHostAndTellsTheRemoteNo() throws {
        let (pane, engine, factory) = try makeFakePane(type: "local")
        defer { pane.close() }
        let host = Host()
        pane.zmodemHost = host
        pane.start()
        let session = try XCTUnwrap(factory.sessions.last)
        session.onOutput?(Data("hello\r\n".utf8))
        XCTAssertTrue(engine.text.contains("hello\r\n"))
        session.onOutput?(Data(ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit))))
        XCTAssertEqual(host.asked, [.receive])
        XCTAssertTrue(session.written.contains(Data(ZModem.abortSequence)), "sz is told no")
        XCTAssertTrue(engine.text.contains("Rejected"))
        XCTAssertFalse(engine.text.contains("**\u{18}B"))
    }

    func testWithoutAHostASessionIsRefused() throws {
        let (pane, _, factory) = try makeFakePane(type: "local")
        defer { pane.close() }
        pane.start()
        let session = try XCTUnwrap(factory.sessions.last)
        session.onOutput?(Data(ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit))))
        XCTAssertTrue(session.written.contains(Data(ZModem.abortSequence)))
    }

    final class AcceptingHost: ZModemHost {
        func zmodemAsk(_ direction: ZModemDirection, in pane: TerminalPane, answer: @escaping (Bool) -> Void) { answer(true) }
        func zmodemSave(_ info: ZModemFileInfo, in pane: TerminalPane, answer: @escaping (ZModemFileSink?) -> Void) {}
        func zmodemChooseFiles(in pane: TerminalPane, answer: @escaping ([ZModemUpload]) -> Void) {}
    }

    /// Review: Restart (and Switch profile) left the bridge in a session, so the new shell's
    /// output disappeared into it.
    func testRestartingEndsATransfer() throws {
        let (pane, engine, factory) = try makeFakePane(type: "local")
        defer { pane.close() }
        let host = AcceptingHost()
        pane.zmodemHost = host
        pane.start()
        try XCTUnwrap(factory.sessions.last).onOutput?(Data(ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit))))
        XCTAssertTrue(pane.zmodem.isActive)
        pane.restart()
        XCTAssertFalse(pane.zmodem.isActive)
        try XCTUnwrap(factory.sessions.last).onOutput?(Data("new shell$ ".utf8))
        XCTAssertTrue(engine.text.hasSuffix("new shell$ "), engine.text.suffix(30).debugDescription)
    }

    /// M11: Ctrl-C is a hotkey whose command writes 0x03 with `send(text:)`, past the engine,
    /// so it never cancelled a transfer.
    func testCtrlCFromTheHotkeyCancels() throws {
        let (pane, _, factory) = try makeFakePane(type: "local")
        defer { pane.close() }
        let host = AcceptingHost()
        pane.zmodemHost = host
        pane.start()
        try XCTUnwrap(factory.sessions.last).onOutput?(Data(ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit))))
        XCTAssertTrue(pane.zmodem.isActive)
        let session = try XCTUnwrap(factory.sessions.last)
        pane.send(text: "\u{03}")
        XCTAssertFalse(pane.zmodem.isActive, "cancelled")
        XCTAssertFalse(session.written.contains(Data([0x03])),
                       "M11: through a terminal, the byte interrupted sz before it could finish the session")
    }
}
