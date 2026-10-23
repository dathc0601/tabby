#if os(macOS)
import XCTest
import TabbyCore
import TabbyTerminal
import TabbyTestSupport
@testable import TabbySerial

/// Serial sessions on a pty pair (Tabby's `SerialSession` + `SerialTabComponent` messages).
final class SerialSessionTests: XCTestCase {
    final class Recorder {
        var output = Data()
        var service = Data()
        var statuses: [SessionStatus] = []
        var closed = 0
        var outputText: String { String(decoding: output, as: UTF8.self) }
        var serviceText: String { String(decoding: service, as: UTF8.self) }
    }

    private func make(_ options: [String: ConfigValue]) -> (SerialSession, Recorder) {
        let session = SerialSession(options: SerialOptions(.object(options)))
        let r = Recorder()
        session.onOutput = { r.output.append($0) }
        session.onServiceOutput = { r.service.append($0) }
        session.onStatus = { r.statuses.append($0) }
        session.onClosed = { _ in r.closed += 1 }
        return (session, r)
    }

    private func line(_ text: String) -> String {
        String(decoding: ServiceMessage.line(text, badge: .serial), as: UTF8.self)
    }

    func testOpeningThePortSaysSoAndConnects() throws {
        let pty = try PTYPair()
        let (session, r) = make(["port": .string(pty.replicaPath), "baudrate": 9600])
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(r.serviceText, line("Port opened"))
        XCTAssertEqual(r.statuses, [.connected])
        session.kill()
    }

    func testBytesGoBothWays() throws {
        let pty = try PTYPair()
        let (session, r) = make(["port": .string(pty.replicaPath), "baudrate": 115200])
        try session.start(cols: 80, rows: 24)
        pty.write("OK\r\n")
        XCTAssertTrue(spinMainLoop { r.outputText == "OK\r\n" })
        session.write(Data("AT\r".utf8))
        XCTAssertEqual(pty.read(count: 3), Data("AT\r".utf8))
        session.kill()
    }

    func testSlowFeedSendsOneByteAtATime() {
        XCTAssertEqual(SerialSession.writes(for: Data("abc".utf8), slowSend: true), [Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        XCTAssertEqual(SerialSession.writes(for: Data("abc".utf8), slowSend: false), [Data("abc".utf8)])
    }

    func testUnpluggingShowsPortClosedAndEnds() throws {
        let pty = try PTYPair()
        let (session, r) = make(["port": .string(pty.replicaPath), "baudrate": 115200])
        try session.start(cols: 80, rows: 24)
        pty.unplug()
        XCTAssertTrue(spinMainLoop { r.closed == 1 })
        XCTAssertTrue(r.serviceText.hasSuffix(line("Port closed") + line("\(pty.replicaPath): session closed")), r.serviceText)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(r.statuses.last, .disconnected)
    }

    func testKillingClosesThePort() throws {
        let pty = try PTYPair()
        let (session, r) = make(["port": .string(pty.replicaPath), "baudrate": 115200])
        try session.start(cols: 80, rows: 24)
        session.kill()
        XCTAssertEqual(r.closed, 1)
        XCTAssertTrue(r.serviceText.hasSuffix(line("\(pty.replicaPath): session closed")))
        XCTAssertFalse(r.serviceText.contains("Port closed"))
        let again = SerialPort(path: pty.replicaPath)
        XCTAssertNoThrow(try again.open(SerialPort.Settings(SerialOptions([:]), baudRate: 9600)), "the port is free again")
        again.close()
        session.kill()
        XCTAssertEqual(r.closed, 1, "ends once")
    }

    func testAPortThatCannotOpenEndsWithTheError() throws {
        let pty = try PTYPair()
        let holder = SerialPort(path: pty.replicaPath)
        try holder.open(SerialPort.Settings(SerialOptions([:]), baudRate: 9600))
        defer { holder.close() }
        let (session, r) = make(["port": .string(pty.replicaPath), "baudrate": 115200])
        XCTAssertNoThrow(try session.start(cols: 80, rows: 24), "the error is shown in the pane, which can then retry")
        XCTAssertTrue(spinMainLoop { r.closed == 1 })
        XCTAssertEqual(r.serviceText, String(decoding: ServiceMessage.error("\(pty.replicaPath) is busy: another program has it open"), as: UTF8.self))
        XCTAssertFalse(session.isRunning)
    }

    func testNoPortIsAnError() throws {
        let (session, r) = make(["baudrate": 115200])
        try session.start(cols: 80, rows: 24)
        XCTAssertTrue(spinMainLoop { r.closed == 1 })
        XCTAssertEqual(r.serviceText, String(decoding: ServiceMessage.error("No serial port selected"), as: UTF8.self))
    }

    func testChangingTheBaudRateWhileConnected() throws {
        let pty = try PTYPair()
        let (session, _) = make(["port": .string(pty.replicaPath), "baudrate": 9600])
        try session.start(cols: 80, rows: 24)
        XCTAssertEqual(session.baudRate, 9600)
        try session.changeBaudRate(57600)
        XCTAssertEqual(session.baudRate, 57600)
        var t = termios()
        let probe = open(pty.replicaPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        defer { close(probe) }
        XCTAssertEqual(tcgetattr(probe, &t), 0)
        XCTAssertEqual(cfgetospeed(&t), speed_t(57600))
        session.kill()
    }

    func testAMissingRateFallsBackToQuickConnectsDefault() throws {
        let pty = try PTYPair()
        let (session, _) = make(["port": .string(pty.replicaPath)])
        try session.start(cols: 80, rows: 24)
        XCTAssertEqual(session.baudRate, 115200)
        session.kill()
    }

    func testTheFactoryAppliesStreamProcessing() throws {
        let profile = Profile(type: "serial", name: "s", options: ["port": "/dev/cu.x", "baudrate": 9600, "outputMode": "hex"])
        let session = try SerialSessionFactory().makeSession(profile: profile, context: SessionContext())
        let processed = try XCTUnwrap(session as? ProcessedSession)
        XCTAssertTrue(processed.inner is SerialSession)
        XCTAssertEqual(processed.processor.options.outputMode, .hex)
        XCTAssertEqual(SerialSessionFactory().profileType, "serial")
    }
}
#endif
