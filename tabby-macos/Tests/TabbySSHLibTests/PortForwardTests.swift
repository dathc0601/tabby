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

    /// Found in the M8 walk: with keep-alive on (Tabby's default), Remote failed with "Global
    /// request tcpip-forward failed" and nothing listened on the server. libssh's keep-alive is
    /// a global request whose refusal arrived later and was taken as tcpip-forward's answer,
    /// which then was never sent; every other keep-alive did the same. Tries at three moments
    /// so one falls after a keep-alive.
    func testARemoteForwardWorksWithKeepAliveOn() async throws {
        var options = SSHConnectionOptions(host: "127.0.0.1", port: sshd.port, user: sshd.user,
                                           knownHostsFile: sshd.directory.appendingPathComponent("known_hosts").path)
        options.privateKeys = [sshd.keyPath]
        options.globalKnownHostsFile = nil
        options.homeDirectory = sshd.directory.path
        options.keepaliveInterval = 1
        let living = SSHConnection(options: options, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await living.connect()
        defer { living.disconnect() }
        try await Task.sleep(nanoseconds: 700_000_000)

        for attempt in 1...3 {
            try await Task.sleep(nanoseconds: 700_000_000)
            let port = try TestSSHD.freePort()
            let id = try await living.addForward(ForwardedPort(type: .remote, port: port, targetAddress: "127.0.0.1", targetPort: echo.port))
            let fd = try connectTCP(port)
            XCTAssertEqual(roundTrip(fd, "remote forward"), "remote forward", "attempt \(attempt)")
            close(fd)
            await living.removeForward(id)
        }
    }

    func testADynamicForwardIsASOCKSProxy() async throws {
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .dynamic, port: port))
        let fd = try ProxyTunnel.open(.socks5(host: "127.0.0.1", port: port), to: "127.0.0.1", port: echo.port, timeout: 5)
        XCTAssertEqual(roundTrip(fd, "through socks"), "through socks")
        close(fd)
    }

    /// Review I1: a slow reader still gets the whole stream after the server closed.
    func testASlowReaderGetsTheWholeStream() async throws {
        let flood = try FloodServer(size: 3_000_000)
        defer { flood.stop() }
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .local, port: port, targetAddress: "127.0.0.1", targetPort: flood.port))
        let fd = try connectTCP(port)
        defer { close(fd) }
        try await Task.sleep(nanoseconds: 1_500_000_000)   // the bridge fills, the server finishes and closes
        let received = readAll(fd)
        XCTAssertEqual(received.count, flood.payload.count)
        XCTAssertTrue(received == flood.payload)
    }

    /// Review C4: a client that goes away while data is queued for it ends its bridge
    /// (no busy loop, no leaked socket or channel).
    func testAClientThatLeavesWithDataQueuedIsCleanedUp() async throws {
        let flood = try FloodServer(size: 8_000_000)
        defer { flood.stop() }
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .local, port: port, targetAddress: "127.0.0.1", targetPort: flood.port))
        let fd = try connectTCP(port)
        try await Task.sleep(nanoseconds: 800_000_000)   // pending fills while nobody reads
        var counts = try await connection.debugCounts()
        XCTAssertEqual(counts.bridges, 1)
        close(fd)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            try await Task.sleep(nanoseconds: 100_000_000)
            counts = try await connection.debugCounts()
        } while (counts.bridges > 0 || counts.channels > 0) && Date() < deadline
        XCTAssertEqual(counts.bridges, 0, "the bridge ended")
        XCTAssertEqual(counts.channels, 0, "its channel was freed")
    }

    // MARK: Review I3: nothing a forward waits for may stall the connection's other users

    /// A shell on the same connection answers within `limit` seconds.
    private func assertShellAnswers(within limit: TimeInterval, file: StaticString = #filePath, line: UInt = #line) async throws {
        let output = OutputCollector()
        let started = Date()   // opening the shell is part of what must not wait
        let shell = try await connection.openShell(term: "xterm", columns: 80, rows: 24, handlers: output.handlers)
        shell.write(Data("echo responsive-$((1+1)); exit\n".utf8))
        while !output.text.contains("responsive-2"), Date().timeIntervalSince(started) < 15 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), limit, "the shell waited for the forward", file: file, line: line)
    }

    /// 192.0.2.1 (TEST-NET-1) is never routed: the server's connect to it hangs.
    func testAForwardToAnUnreachableHostDoesNotStallTheConnection() async throws {
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .local, port: port, targetAddress: "192.0.2.1", targetPort: 9))
        let client = try connectTCP(port)
        defer { close(client) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await assertShellAnswers(within: 2)
    }

    func testASilentSOCKSClientDoesNotStallTheConnection() async throws {
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .dynamic, port: port))
        let client = try connectTCP(port)   // and never says anything
        defer { close(client) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await assertShellAnswers(within: 2)
    }

    func testARemoteForwardToAnUnreachableTargetDoesNotStallTheConnection() async throws {
        let port = try TestSSHD.freePort()
        _ = try await connection.addForward(ForwardedPort(type: .remote, port: port, targetAddress: "192.0.2.1", targetPort: 9))
        let client = try connectTCP(port)   // the server forwards it back; this Mac's connect to the target hangs
        defer { close(client) }
        try await Task.sleep(nanoseconds: 200_000_000)
        try await assertShellAnswers(within: 2)
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
