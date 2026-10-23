#if os(macOS)
import XCTest
import TabbyCore
import TabbyTestSupport
@testable import TabbySerial

/// `SerialPort` on a pseudo-terminal pair: the replica plays the serial device's node. No
/// test opens a real `/dev/cu.*`.
final class SerialPortTests: XCTestCase {
    private func settings(_ options: [String: ConfigValue] = [:], baud: Int = 115200) -> SerialPort.Settings {
        SerialPort.Settings(SerialOptions(.object(options)), baudRate: baud)
    }

    private func attributes(_ port: SerialPort) throws -> termios {
        var t = termios()
        XCTAssertEqual(tcgetattr(port.fileDescriptor, &t), 0)
        return t
    }

    func testBytesGoBothWays() throws {
        let pty = try PTYPair()
        let port = SerialPort(path: pty.replicaPath)
        var received = Data()
        port.onData = { received.append($0) }
        try port.open(settings())
        defer { port.close() }
        pty.write("hello\n")
        XCTAssertTrue(spinMainLoop { received == Data("hello\n".utf8) }, "raw mode: no translation, no echo")
        port.write(Data("world\r\n".utf8))
        XCTAssertEqual(pty.read(count: 7), Data("world\r\n".utf8), "no output processing either")
    }

    func testTheLineSettingsAreApplied() throws {
        let pty = try PTYPair()
        let port = SerialPort(path: pty.replicaPath)
        try port.open(settings(["databits": 7, "parity": "odd", "stopbits": 2, "rtscts": true, "xon": true, "xoff": true, "xany": true]))
        defer { port.close() }
        let t = try attributes(port)
        XCTAssertEqual(t.c_cflag & tcflag_t(CSIZE), tcflag_t(CS7))
        XCTAssertNotEqual(t.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertNotEqual(t.c_cflag & tcflag_t(PARODD), 0)
        XCTAssertNotEqual(t.c_cflag & tcflag_t(CSTOPB), 0)
        XCTAssertNotEqual(t.c_cflag & tcflag_t(CLOCAL), 0)
        XCTAssertNotEqual(t.c_cflag & tcflag_t(CREAD), 0)
        XCTAssertEqual(t.c_iflag & tcflag_t(IXON | IXOFF | IXANY), tcflag_t(IXON | IXOFF | IXANY))
        XCTAssertEqual(t.c_lflag & tcflag_t(ICANON | ECHO), 0, "raw")
        // A pty keeps whatever speed it is given; a real port's driver checks it.
        var copy = t
        XCTAssertEqual(cfgetospeed(&copy), speed_t(115200))

        let plain = try PTYPair()
        let defaults = SerialPort(path: plain.replicaPath)
        try defaults.open(settings())
        defer { defaults.close() }
        let d = try attributes(defaults)
        XCTAssertEqual(d.c_cflag & tcflag_t(CSIZE), tcflag_t(CS8))
        XCTAssertEqual(d.c_cflag & tcflag_t(PARENB | CSTOPB), 0)
        XCTAssertEqual(d.c_iflag & tcflag_t(IXON | IXOFF | IXANY), 0)
    }

    func testTheBaudRateChangesWhileOpen() throws {
        let pty = try PTYPair()
        let port = SerialPort(path: pty.replicaPath)
        try port.open(settings(baud: 9600))
        defer { port.close() }
        try port.apply(settings(baud: 19200))
        var t = try attributes(port)
        XCTAssertEqual(cfgetospeed(&t), speed_t(19200))
    }

    func testRatesTermiosLacksUseTheSpeedIoctl() {
        XCTAssertFalse(SerialPort.needsSpeedIoctl(115200))
        XCTAssertFalse(SerialPort.needsSpeedIoctl(230400))
        XCTAssertTrue(SerialPort.needsSpeedIoctl(460800))
        XCTAssertTrue(SerialPort.needsSpeedIoctl(250000))
    }

    // Two tabs can't share a port. (Other programs are kept out by TIOCEXCL, which a real
    // port's driver enforces and a pty ignores, so only M9 on hardware shows that part.)
    func testAPortIsOpenedExclusively() throws {
        let pty = try PTYPair()
        let first = SerialPort(path: pty.replicaPath)
        try first.open(settings())
        defer { first.close() }
        let second = SerialPort(path: pty.replicaPath)
        XCTAssertThrowsError(try second.open(settings())) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "\(pty.replicaPath) is busy: another program has it open")
        }
    }

    func testAMissingDeviceIsAnError() {
        let port = SerialPort(path: "/dev/cu.tabbymac-test-no-such-port")
        XCTAssertThrowsError(try port.open(settings())) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription,
                           "Cannot open /dev/cu.tabbymac-test-no-such-port: No such file or directory")
        }
    }

    func testUnpluggingIsReported() throws {
        let pty = try PTYPair()
        let port = SerialPort(path: pty.replicaPath)
        var hangups = 0
        port.onHangup = { hangups += 1 }
        try port.open(settings())
        pty.unplug()
        XCTAssertTrue(spinMainLoop { hangups == 1 })
        port.close()
        spinMainLoop(timeout: 0.2) { false }
        XCTAssertEqual(hangups, 1, "once")
    }

    func testClosingIsNotAHangup() throws {
        let pty = try PTYPair()
        let port = SerialPort(path: pty.replicaPath)
        var hangups = 0
        port.onHangup = { hangups += 1 }
        try port.open(settings())
        port.close()
        let again = SerialPort(path: pty.replicaPath)
        XCTAssertNoThrow(try again.open(settings()), "closing gives the port back")
        again.close()
        spinMainLoop(timeout: 0.2) { false }
        XCTAssertEqual(hangups, 0)
    }
}
#endif
