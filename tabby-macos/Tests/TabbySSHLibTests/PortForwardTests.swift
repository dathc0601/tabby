#if os(macOS)
import XCTest
import TabbyCore
import TabbySSH
@testable import TabbySSHLib

/// Local, remote and dynamic forwards, added and removed while connected.
final class PortForwardTests: XCTestCase {
    var sshd: TestSSHD!
    var echo: EchoServer!
    var connection: SSHConnection!

    override func setUp() async throws {
        sshd = try TestSSHD()
        echo = try EchoServer()
        var options = SSHConnectionOptions(host: "127.0.0.1", port: sshd.port, user: sshd.user,
                                           knownHostsFile: sshd.directory.appendingPathComponent("known_hosts").path)
        options.privateKeys = [sshd.keyPath]
        options.globalKnownHostsFile = nil
        options.homeDirectory = sshd.directory.path
        connection = SSHConnection(options: options, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
    }

    override func tearDown() async throws {
        connection.disconnect()
        echo.stop()
        sshd.stop()
    }

    func connectTCP(_ port: Int) throws -> Int32 {
        try ProxyTunnel.connect(host: "127.0.0.1", port: port, timeout: 5)
    }

    func testALocalForwardReachesItsTarget() async throws {
        let port = try TestSSHD.freePort()
        let id = try await connection.addForward(ForwardedPort(type: .local, port: port, targetAddress: "127.0.0.1", targetPort: echo.port))
        let fd = try connectTCP(port)
        XCTAssertEqual(roundTrip(fd, "local forward"), "local forward")
        close(fd)
        XCTAssertEqual(connection.forwards.map(\.id), [id])
        await connection.removeForward(id)
        XCTAssertTrue(connection.forwards.isEmpty)
        XCTAssertThrowsError(try connectTCP(port), "the listener is gone")
    }

    func testARemoteForwardComesBackToThisMac() async throws {
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .remote, port: port, targetAddress: "127.0.0.1", targetPort: echo.port))
        // The server is this Mac: connecting to its forwarded port comes back through SSH.
        let fd = try connectTCP(port)
        XCTAssertEqual(roundTrip(fd, "remote forward"), "remote forward")
        close(fd)
    }

    func testADynamicForwardIsASOCKSProxy() async throws {
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .dynamic, port: port))
        let fd = try ProxyTunnel.open(.socks5(host: "127.0.0.1", port: port), to: "127.0.0.1", port: echo.port, timeout: 5)
        XCTAssertEqual(roundTrip(fd, "through socks"), "through socks")
        close(fd)
    }

    func testAPortInUseIsAnError() async throws {
        let port = try TestSSHD.freePort()
        let forward = ForwardedPort(type: .local, port: port, targetAddress: "127.0.0.1", targetPort: echo.port)
        _ = try await connection.addForward(forward)
        do {
            _ = try await connection.addForward(forward)
            XCTFail("bound the same port twice")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Failed to forward port \(forward.summary)"), error.localizedDescription)
        }
    }
}
#endif
