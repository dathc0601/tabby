#if os(macOS)
import XCTest
import TabbyCore
import TabbySSH
import TabbyTerminal
@testable import TabbySSHLib

/// Accepts host keys and records what the session asked.
@MainActor
final class AcceptingUI: SSHSessionUI {
    var hostKeys = 0
    var notices: [String] = []

    func notify(title: String, detail: String, isError: Bool, for session: LibSSHSession) {
        notices.append("\(title): \(detail)")
    }

    func verifyHostKey(_ request: HostKeyRequest, for session: LibSSHSession) async -> HostKeyDecision {
        hostKeys += 1
        return .acceptAndRemember
    }

    func password(user: String, host: String, for session: LibSSHSession) async -> SecretAnswer? { nil }
    func passphrase(keyPath: String, for session: LibSSHSession) async -> SecretAnswer? { nil }
    func keyboardInteractive(_ round: KeyboardInteractiveRound, for session: LibSSHSession) async -> KeyboardInteractiveAnswer? { nil }
    func username(host: String, for session: LibSSHSession) async -> String? { nil }
}

/// The library backend as a terminal session: status, service lines, output, exit.
@MainActor
final class LibSSHSessionTests: XCTestCase {
    var sshd: TestSSHD!
    let ui = AcceptingUI()

    override func setUp() async throws {
        sshd = try TestSSHD()
    }

    override func tearDown() async throws {
        sshd.stop()
    }

    func makeSession(key: String? = nil, cwd: String? = nil, forwards: [ForwardedPort] = []) -> LibSSHSession {
        var options: [String: ConfigValue] = ["host": "127.0.0.1", "port": .int(sshd.port), "user": .string(sshd.user),
                                              "privateKeys": .array([.string(key ?? sshd.keyPath)])]
        if let cwd { options["cwd"] = .string(cwd) }
        if !forwards.isEmpty { options["forwardedPorts"] = .array(forwards.map(\.configValue)) }
        let profile = Profile(id: "ssh:test", type: "ssh", name: "test box", options: .object(options))
        let home = sshd.directory.appendingPathComponent("home").path
        let environment = LibSSHSession.Environment(
            knownHostsFile: sshd.directory.appendingPathComponent("known_hosts").path, globalKnownHostsFile: nil,
            agentSocket: { nil }, homeDirectory: home, passwords: InMemoryPasswordStore())
        let session = LibSSHSession(profile: profile, environment: environment)
        session.ui = ui
        return session
    }

    final class Recorder {
        var output = Data()
        var statuses: [SessionStatus] = []
        var closed: Int32?? = nil
        var text: String { String(decoding: output, as: UTF8.self) }
    }

    func attach(_ session: LibSSHSession) -> Recorder {
        let r = Recorder()
        session.onOutput = { r.output.append($0) }
        session.onStatus = { r.statuses.append($0) }
        session.onClosed = { r.closed = .some($0) }
        return r
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "wait", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testASessionConnectsRunsAndReportsItsExit() async throws {
        let session = makeSession()
        let r = attach(session)
        try session.start(cols: 90, rows: 20)
        XCTAssertTrue(session.isRunning)
        try await waitUntil { r.statuses.contains(.connected) }
        XCTAssertEqual(r.statuses.first, .connecting("Connecting to test box"))
        XCTAssertTrue(r.text.contains(" SSH \u{1b}[0m Connecting to test box"), r.text)
        XCTAssertTrue(r.text.contains("Host key fingerprint: ssh-ed25519 \(sshd.hostKeyFingerprint)"), r.text)
        XCTAssertEqual(ui.hostKeys, 1)
        session.write(Data("stty size; echo hi-$((1+1)); exit 7\n".utf8))
        try await waitUntil { r.closed != nil }
        XCTAssertEqual(r.closed, .some(7))
        XCTAssertTrue(r.text.contains("20 90"), r.text)
        XCTAssertTrue(r.text.contains("hi-2"), r.text)
        XCTAssertTrue(r.text.contains("127.0.0.1: session closed"), r.text)
        XCTAssertEqual(r.statuses.last, .disconnected)
        XCTAssertFalse(session.isRunning)
    }

    func testAFailedLoginPrintsTheReasonAndCloses() async throws {
        let stranger = sshd.directory.appendingPathComponent("stranger").path
        try TestSSHD.keygen(stranger, passphrase: "")
        let session = makeSession(key: stranger)
        let r = attach(session)
        try session.start(cols: 80, rows: 24)
        try await waitUntil { r.closed != nil }
        XCTAssertEqual(r.closed, .some(nil))
        XCTAssertTrue(r.text.contains("Authentication rejected"), r.text)
        XCTAssertFalse(r.statuses.contains(.connected))
        XCTAssertEqual(r.statuses.last, .disconnected)
    }

    func testTheProfileDirectoryIsEnteredAfterConnecting() async throws {
        let directory = sshd.directory.appendingPathComponent("work dir")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = makeSession(cwd: directory.path)
        let r = attach(session)
        try session.start(cols: 200, rows: 24)
        try await waitUntil { r.statuses.contains(.connected) }
        session.write(Data("echo at:$(pwd); exit\n".utf8))
        try await waitUntil { r.closed != nil }
        XCTAssertTrue(r.text.contains("at:\(directory.resolvingSymlinksInPath().path)") || r.text.contains("at:\(directory.path)"), r.text)
    }

    /// Two tabs of a profile share one connection; closing one leaves the other working.
    func testTabsShareAConnection() async throws {
        let first = makeSession()
        let connector = SSHConnector(environment: first.environment)
        first.connector = connector
        let second = makeSession()
        second.connector = connector
        let r1 = attach(first)
        let r2 = attach(second)
        try first.start(cols: 80, rows: 24)
        try second.start(cols: 80, rows: 24)
        try await waitUntil { r1.statuses.contains(.connected) && r2.statuses.contains(.connected) }
        XCTAssertTrue(first.connection === second.connection)
        XCTAssertEqual(ui.hostKeys, 1)
        first.write(Data("exit\n".utf8))
        try await waitUntil { r1.closed != nil }
        second.write(Data("echo still-$((40+2)); exit\n".utf8))
        try await waitUntil { r2.closed != nil }
        XCTAssertTrue(r2.text.contains("still-42"), r2.text)
        try await waitUntil { connector.sharedCount == 0 }
    }

    /// The profile's forwards start once connected; one that cannot start is reported, and
    /// the session carries on.
    func testTheProfilesForwardsStart() async throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let busy = try PortListenerHog()
        defer { busy.stop() }
        let port = try TestSSHD.freePort()
        let good = ForwardedPort(type: .local, port: port, targetAddress: "127.0.0.1", targetPort: echo.port)
        let bad = ForwardedPort(type: .local, port: busy.port, targetAddress: "127.0.0.1", targetPort: echo.port)
        let session = makeSession(forwards: [good, bad])
        let r = attach(session)
        try session.start(cols: 80, rows: 24)
        try await waitUntil { session.connection?.forwards.count == 1 && !self.ui.notices.isEmpty }
        XCTAssertEqual(session.connection?.forwards.map(\.forward), [good])
        let fd = try ProxyTunnel.connect(host: "127.0.0.1", port: port, timeout: 5)
        XCTAssertEqual(roundTrip(fd, "profile forward"), "profile forward")
        close(fd)
        XCTAssertTrue(ui.notices.first?.hasPrefix("Failed to forward port: \(bad.summary)") ?? false, "\(ui.notices)")
        XCTAssertTrue(r.text.contains("Failed to forward port \(bad.summary)"), r.text)
        session.kill()
        try await waitUntil { r.closed != nil }
    }

    func testKillWhileConnectedClosesTheSession() async throws {
        let session = makeSession()
        let r = attach(session)
        try session.start(cols: 80, rows: 24)
        try await waitUntil { r.statuses.contains(.connected) }
        session.kill()
        try await waitUntil { r.closed != nil }
        XCTAssertFalse(session.isRunning)
    }
}
#endif
