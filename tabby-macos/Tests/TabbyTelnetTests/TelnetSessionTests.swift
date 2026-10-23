#if os(macOS)
import XCTest
import TabbyCore
import TabbyTerminal
import TabbyTestSupport
@testable import TabbyTelnet

/// Telnet sessions against a scripted server on 127.0.0.1 (nothing leaves the Mac).
final class TelnetSessionTests: XCTestCase {
    let IAC: UInt8 = 255, DO: UInt8 = 253, WILL: UInt8 = 251, SB: UInt8 = 250, SE: UInt8 = 240
    let ECHO: UInt8 = 1, SGA: UInt8 = 3, TTYPE: UInt8 = 24, NAWS: UInt8 = 31

    final class Recorder {
        var output = Data()
        var service = Data()
        var statuses: [SessionStatus] = []
        var closed: [Int32?] = []
        var echo: [Bool] = []
        var peerEcho: [Bool] = []
        var outputText: String { String(decoding: output, as: UTF8.self) }
        var serviceText: String { String(decoding: service, as: UTF8.self) }
    }

    private func make(port: Int, host: String = "127.0.0.1") -> (TelnetSession, Recorder) {
        let session = TelnetSession(options: TelnetOptions(host: host, port: port))
        let r = Recorder()
        session.onOutput = { r.output.append($0) }
        session.onServiceOutput = { r.service.append($0) }
        session.onStatus = { r.statuses.append($0) }
        session.onClosed = { r.closed.append($0) }
        session.onLocalEchoChanged = { r.echo.append($0) }
        session.onPeerEchoChanged = { r.peerEcho.append($0) }
        return (session, r)
    }

    func testConnectingShowsTabbysServiceLines() throws {
        let server = try ScriptedTCPServer()
        let (session, r) = make(port: server.port)
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(spinMainLoop { r.statuses.contains(.connected) })
        XCTAssertEqual(r.serviceText, String(decoding: ServiceMessage.line("Connecting to 127.0.0.1", badge: .telnet)
            + ServiceMessage.line("Connected", badge: .telnet), as: UTF8.self))
        session.kill()
    }

    func testNegotiationWithAServer() throws {
        let server = try ScriptedTCPServer()
        let (session, r) = make(port: server.port)
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { server.hasClient })
        server.send(Data([IAC, DO, TTYPE, IAC, DO, NAWS, IAC, WILL, ECHO, IAC, SB, TTYPE, 1, IAC, SE]) + Data("login: ".utf8))
        let naws = Data([IAC, SB, NAWS, 0, 80, 0, 24, IAC, SE])
        let ttype = Data([IAC, SB, TTYPE, 0]) + Data("XTERM-256COLOR".utf8) + Data([IAC, SE])
        XCTAssertTrue(spinMainLoop { server.received.contains(naws) && server.received.contains(ttype) && r.outputText == "login: " },
                      "received \(Array(server.received)), output \(r.outputText)")
        for offer in [Data([IAC, DO, SGA]), Data([IAC, WILL, TTYPE]), Data([IAC, WILL, NAWS]), Data([IAC, DO, ECHO])] {
            XCTAssertTrue(server.received.contains(offer), "sent \(Array(offer))")
        }

        session.resize(cols: 100, rows: 30)
        XCTAssertTrue(spinMainLoop { server.received.contains(Data([IAC, SB, NAWS, 0, 100, 0, 30, IAC, SE])) })

        session.write(Data([0x61, 0xff]))
        XCTAssertTrue(spinMainLoop { server.received.suffix(3) == Data([0x61, 0xff, 0xff]) }, "0xFF is escaped")
        session.kill()
    }

    func testTheServerCanTurnOnLocalEcho() throws {
        let server = try ScriptedTCPServer()
        let (session, r) = make(port: server.port)
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { server.hasClient })
        server.send(Data([IAC, DO, ECHO]))
        XCTAssertTrue(spinMainLoop { r.echo == [true] })
        server.send(Data([IAC, WILL, ECHO]))
        XCTAssertTrue(spinMainLoop { r.peerEcho == [true] && r.echo == [true, false] }, "the server echoes; we stop")
        session.kill()
    }

    // Review: writes before the connection is ready (typing while connecting, login scripts
    // with no expect, which the pane sends right after start) were dropped.
    func testWhatIsWrittenWhileConnectingIsSentOnceConnected() throws {
        let server = try ScriptedTCPServer()
        let (session, r) = make(port: server.port)
        try session.start(cols: 80, rows: 24)
        session.write(Data("wake\r".utf8))
        XCTAssertTrue(spinMainLoop { r.statuses.contains(.connected) })
        XCTAssertTrue(spinMainLoop { server.received == Data("wake\r".utf8) }, "received \(Array(server.received))")
        session.kill()
    }

    func testARawSocketIsPlainBytes() throws {
        let echo = try EchoServer()
        let (session, r) = make(port: echo.port)
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { r.statuses.contains(.connected) })
        session.write(Data("ping\r\n".utf8))
        XCTAssertTrue(spinMainLoop { r.outputText == "ping\r\n" }, r.outputText)
        session.kill()
    }

    func testARefusedConnectionEndsTheSessionWithTheError() throws {
        let (session, r) = make(port: try freeTCPPort())
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { !r.closed.isEmpty })
        XCTAssertTrue(r.serviceText.contains(String(decoding: ServiceMessage.error("Socket error: Connection refused"), as: UTF8.self)),
                      r.serviceText)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(r.statuses.last, .disconnected)
        XCTAssertEqual(r.closed.count, 1)
    }

    func testTheServerClosingEndsTheSession() throws {
        let server = try ScriptedTCPServer()
        let (session, r) = make(port: server.port)
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { r.statuses.contains(.connected) && server.hasClient })
        server.closeClient()
        XCTAssertTrue(spinMainLoop { !r.closed.isEmpty })
        XCTAssertTrue(r.serviceText.hasSuffix(String(decoding: ServiceMessage.line("Connection closed", badge: .telnet)
            + ServiceMessage.line("127.0.0.1: session closed", badge: .telnet), as: UTF8.self)), r.serviceText)
        XCTAssertFalse(session.isRunning)
    }

    func testKillingTheSessionClosesTheSocket() throws {
        let server = try ScriptedTCPServer()
        let (session, r) = make(port: server.port)
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { r.statuses.contains(.connected) })
        session.kill()
        XCTAssertTrue(spinMainLoop { server.clientHasClosed })
        XCTAssertTrue(spinMainLoop { r.closed.count == 1 })
        XCTAssertTrue(r.serviceText.hasSuffix(String(decoding: ServiceMessage.line("127.0.0.1: session closed", badge: .telnet), as: UTF8.self)))
        XCTAssertFalse(r.serviceText.contains("Connection closed"))
        spinMainLoop(timeout: 0.3) { false }
        XCTAssertEqual(r.closed.count, 1, "ends once")
    }

    func testAProfileWithoutAHostDoesNotStart() {
        let (session, _) = make(port: 23, host: "")
        XCTAssertThrowsError(try session.start(cols: 80, rows: 24))
    }

    func testTheFactoryAppliesStreamProcessing() throws {
        let profile = Profile(type: "telnet", name: "t", options: ["host": "127.0.0.1", "port": 23, "inputMode": "local-echo"])
        let session = try TelnetSessionFactory().makeSession(profile: profile, context: SessionContext())
        let processed = try XCTUnwrap(session as? ProcessedSession)
        XCTAssertTrue(processed.inner is TelnetSession)
        XCTAssertEqual(processed.processor.options.inputMode, .localEcho)
        XCTAssertEqual(TelnetSessionFactory().profileType, "telnet")
    }
}
#endif
