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
}
