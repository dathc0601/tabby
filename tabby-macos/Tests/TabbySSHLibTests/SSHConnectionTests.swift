#if os(macOS)
import XCTest
import TabbyCore
import TabbySSH
@testable import TabbySSHLib

/// Answers prompts from a script and records what was asked.
@MainActor
final class ScriptedPrompter: SSHConnectionPrompter {
    var hostKeyDecision: HostKeyDecision = .acceptAndRemember
    var passphrases: [String] = []
    var hostKeys: [HostKeyRequest] = []
    var passphraseRequests: [String] = []
    var messages: [String] = []

    nonisolated init() {}

    func verifyHostKey(_ request: HostKeyRequest) async -> HostKeyDecision {
        hostKeys.append(request)
        return hostKeyDecision
    }

    func password(user: String, host: String) async -> SecretAnswer? { nil }

    func passphrase(keyPath: String) async -> SecretAnswer? {
        passphraseRequests.append(keyPath)
        return passphrases.isEmpty ? nil : SecretAnswer(value: passphrases.removeFirst(), remember: true)
    }

    func keyboardInteractive(_ round: KeyboardInteractiveRound) async -> KeyboardInteractiveAnswer? { nil }

    func username(host: String) async -> String? { nil }

    func message(_ text: String) {
        messages.append(text)
    }
}

final class SSHConnectionTests: XCTestCase {
    var sshd: TestSSHD!
    var home: URL!

    override func setUpWithError() throws {
        sshd = try TestSSHD()
        home = sshd.directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        sshd.stop()
        super.tearDown()
    }

    var knownHosts: String { sshd.directory.appendingPathComponent("app_known_hosts").path }

    func options(keys: [String]) -> SSHConnectionOptions {
        var options = SSHConnectionOptions(host: "127.0.0.1", port: sshd.port, user: sshd.user)
        options.privateKeys = keys
        options.knownHostsFile = knownHosts
        options.globalKnownHostsFile = nil
        options.homeDirectory = home.path
        options.agentSocket = nil
        return options
    }

    func testPublicKeyLoginRunsAShellAndRemembersTheHostKey() async throws {
        let prompter = ScriptedPrompter()
        let connection = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: prompter, passwords: InMemoryPasswordStore())
        try await connection.connect()
        let asked = await prompter.hostKeys
        XCTAssertEqual(asked.map(\.fingerprint), [sshd.hostKeyFingerprint])
        XCTAssertEqual(asked.first?.keyType, "ssh-ed25519")
        XCTAssertNil(asked.first?.previousFingerprint)
        let saved = try String(contentsOfFile: knownHosts, encoding: .utf8)
        XCTAssertTrue(saved.contains("[127.0.0.1]:\(sshd.port) ssh-ed25519 "), saved)

        let output = OutputCollector()
        let shell = try await connection.openShell(term: "xterm-256color", columns: 100, rows: 30, handlers: output.handlers)
        shell.write(Data("stty size; echo tabby-$((6*7)); exit 3\n".utf8))
        let status = try await output.waitForClose(timeout: 10)
        XCTAssertEqual(status, 3)
        XCTAssertTrue(output.text.contains("30 100"), output.text)
        XCTAssertTrue(output.text.contains("tabby-42"), output.text)
        connection.disconnect()

        // Second connection: the key is known, no question.
        let again = ScriptedPrompter()
        let second = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: again, passwords: InMemoryPasswordStore())
        try await second.connect()
        let askedAgain = await again.hostKeys
        XCTAssertTrue(askedAgain.isEmpty)
        second.disconnect()
    }

    func testARejectedHostKeyStopsTheConnection() async throws {
        let prompter = ScriptedPrompter()
        await MainActor.run { prompter.hostKeyDecision = .reject }
        let connection = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: prompter, passwords: InMemoryPasswordStore())
        do {
            try await connection.connect()
            XCTFail("connected after rejecting the host key")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .hostKeyRejected)
        }
        let saved = (try? String(contentsOfFile: knownHosts, encoding: .utf8)) ?? ""
        XCTAssertFalse(saved.contains("ssh-ed25519"), "a rejected key is not saved")
    }

    func testAChangedHostKeyShowsThePreviousFingerprint() async throws {
        let other = try TestSSHD(name: "other")
        defer { other.stop() }
        // known_hosts says 127.0.0.1:port has another server's key.
        let line = "[127.0.0.1]:\(sshd.port) " + (try String(contentsOfFile: other.hostKeyPath + ".pub", encoding: .utf8))
        try line.write(toFile: knownHosts, atomically: true, encoding: .utf8)
        let prompter = ScriptedPrompter()
        await MainActor.run { prompter.hostKeyDecision = .reject }
        let connection = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: prompter, passwords: InMemoryPasswordStore())
        await XCTAssertThrowsErrorAsync(try await connection.connect())
        let asked = await prompter.hostKeys
        XCTAssertEqual(asked.first?.fingerprint, sshd.hostKeyFingerprint)
        XCTAssertEqual(asked.first?.previousFingerprint, other.hostKeyFingerprint)
    }

    /// Review I6: remembering a changed key replaces the old one (Tabby replaces it), so the
    /// old key — perhaps the reason it was rotated — is no longer trusted.
    func testRememberingAChangedKeyReplacesTheOldOne() async throws {
        let other = try TestSSHD(name: "other")
        defer { other.stop() }
        let unrelated = "unrelated.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHm2b2k9xqGqH6W8m1q2wqk8nF2mQe1QwYbWq0B6m6+B\n"
        let stale = "[127.0.0.1]:\(sshd.port) " + (try String(contentsOfFile: other.hostKeyPath + ".pub", encoding: .utf8))
        try (unrelated + stale).write(toFile: knownHosts, atomically: true, encoding: .utf8)
        let prompter = ScriptedPrompter()
        let connection = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: prompter, passwords: InMemoryPasswordStore())
        try await connection.connect()
        connection.disconnect()
        let lines = try String(contentsOfFile: knownHosts, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("[127.0.0.1]:\(sshd.port) ") }.count, 1)
        XCTAssertFalse(lines.contains(stale.trimmingCharacters(in: .newlines)), "the old key is gone")
        XCTAssertTrue(lines.contains(unrelated.trimmingCharacters(in: .newlines)), "other hosts are kept")
        XCTAssertEqual(KnownHostsLookup.fingerprints(host: "127.0.0.1", port: sshd.port, files: [knownHosts]).map(\.fingerprint),
                       [sshd.hostKeyFingerprint])
    }

    func testHashedKnownHostsEntriesAreRead() throws {
        let file = sshd.directory.appendingPathComponent("hashed_known_hosts").path
        let line = "[127.0.0.1]:\(sshd.port) " + (try String(contentsOfFile: sshd.hostKeyPath + ".pub", encoding: .utf8))
        try line.write(toFile: file, atomically: true, encoding: .utf8)
        TestSSHD.run("/usr/bin/ssh-keygen", ["-H", "-f", file])
        XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).hasPrefix("|1|"))
        XCTAssertEqual(KnownHostsLookup.fingerprints(host: "127.0.0.1", port: sshd.port, files: [file]).map(\.fingerprint),
                       [sshd.hostKeyFingerprint])
        XCTAssertTrue(KnownHostsLookup.fingerprints(host: "127.0.0.1", port: sshd.port + 1, files: [file]).isEmpty)
    }

    func testAnEncryptedKeyAsksForItsPassphraseOnceThenUsesTheKeychain() async throws {
        let passwords = InMemoryPasswordStore()
        let prompter = ScriptedPrompter()
        await MainActor.run { prompter.passphrases = [sshd.passphrase] }
        let connection = SSHConnection(options: options(keys: [sshd.encryptedKeyPath]), prompter: prompter, passwords: passwords)
        try await connection.connect()
        connection.disconnect()
        let requests = await prompter.passphraseRequests
        XCTAssertEqual(requests, [sshd.encryptedKeyPath])
        let id = try XCTUnwrap(SSHSession.keyID(path: sshd.encryptedKeyPath))
        XCTAssertEqual(passwords.passphrase(keyID: id), sshd.passphrase, "remembered after the login worked")

        let quiet = ScriptedPrompter()
        let second = SSHConnection(options: options(keys: [sshd.encryptedKeyPath]), prompter: quiet, passwords: passwords)
        try await second.connect()
        second.disconnect()
        let asked = await quiet.passphraseRequests
        XCTAssertTrue(asked.isEmpty, "the saved passphrase is used")
    }

    /// A direct-tcpip channel bridged to a local socket: what jump hosts and local forwards use.
    func testABridgedChannelCarriesBytesBothWays() async throws {
        let echo = try EchoServer()
        defer { echo.stop() }
        let connection = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        defer { connection.disconnect() }
        let fd = try await connection.openBridgedSocket(to: "127.0.0.1", port: echo.port)
        defer { close(fd) }
        XCTAssertEqual(roundTrip(fd, "hello through ssh"), "hello through ssh")
        let big = String(repeating: "0123456789abcdef", count: 16_384)
        XCTAssertEqual(roundTrip(fd, big).count, big.count, "256 KiB, more than one channel window")
    }

    func testABridgeToAClosedPortFails() async throws {
        let closedPort = try TestSSHD.freePort()
        let connection = SSHConnection(options: options(keys: [sshd.keyPath]), prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        defer { connection.disconnect() }
        await XCTAssertThrowsErrorAsync(_ = try await connection.openBridgedSocket(to: "127.0.0.1", port: closedPort))
    }

    func testThroughASOCKS5Proxy() async throws {
        let proxy = try TestProxy(.socks5)
        defer { proxy.stop() }
        var o = options(keys: [sshd.keyPath])
        o.proxy = .socks5(host: "127.0.0.1", port: proxy.port)
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        connection.disconnect()
        XCTAssertEqual(proxy.tunnels, 1)
    }

    func testThroughAnHTTPProxy() async throws {
        let proxy = try TestProxy(.http)
        defer { proxy.stop() }
        var o = options(keys: [sshd.keyPath])
        o.proxy = .http(host: "127.0.0.1", port: proxy.port)
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        connection.disconnect()
        XCTAssertEqual(proxy.tunnels, 1)
    }

    func testAProxyThatCannotReachTheHostIsAnError() async throws {
        let proxy = try TestProxy(.http)
        defer { proxy.stop() }
        var o = options(keys: [sshd.keyPath])
        o.port = try TestSSHD.freePort()
        o.proxy = .http(host: "127.0.0.1", port: proxy.port)
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        do {
            try await connection.connect()
            XCTFail("connected through a proxy that answered 502")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .connectFailed("Proxy: the HTTP proxy answered 502 Bad Gateway"))
        }
    }

    func testTheAgentLogsIn() async throws {
        let agent = try TestAgent(directory: sshd.directory, keys: [sshd.keyPath])
        defer { agent.stop() }
        var o = options(keys: [])
        o.auth = .agent
        o.agentSocket = agent.socketPath
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        connection.disconnect()
    }

    func testWithoutAnAgentAgentAuthFails() async throws {
        var o = options(keys: [])
        o.auth = .agent
        o.agentSocket = nil
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        await XCTAssertThrowsErrorAsync(try await connection.connect())
    }

    /// With forwarding, programs on the server reach this Mac's agent.
    func testAgentForwarding() async throws {
        let agent = try TestAgent(directory: sshd.directory, keys: [sshd.keyPath])
        defer { agent.stop() }
        var o = options(keys: [sshd.keyPath])
        o.agentSocket = agent.socketPath
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        defer { connection.disconnect() }
        let output = OutputCollector()
        let shell = try await connection.openShell(term: "xterm", columns: 200, rows: 24, handlers: output.handlers, forwardAgent: true)
        shell.write(Data("ssh-add -l; exit\n".utf8))
        _ = try await output.waitForClose(timeout: 10)
        XCTAssertTrue(output.text.contains("tabby-test (ED25519)"), output.text)
    }

    /// The profile editor's "Test connection": connect and log in, no shell, then report.
    func testTestingAConnection() async throws {
        let ok = await SSHConnectionTest.run(options: options(keys: [sshd.keyPath]), prompter: ScriptedPrompter(),
                                             passwords: InMemoryPasswordStore())
        XCTAssertEqual(ok, .success("Connected as \(sshd.user) · ssh-ed25519 \(sshd.hostKeyFingerprint)"))
        let stranger = sshd.directory.appendingPathComponent("stranger").path
        try TestSSHD.keygen(stranger, passphrase: "")
        let rejected = await SSHConnectionTest.run(options: options(keys: [stranger]), prompter: ScriptedPrompter(),
                                                   passwords: InMemoryPasswordStore())
        XCTAssertEqual(rejected, .failure("Authentication rejected"))
        var unreachable = options(keys: [sshd.keyPath])
        unreachable.port = try TestSSHD.freePort()
        let refused = await SSHConnectionTest.run(options: unreachable, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        guard case .failure(let message) = refused else { return XCTFail("connected to a closed port") }
        XCTAssertFalse(message.isEmpty)
    }

    /// Review C5: without a forwarding request, agent and X11 channels opened by the
    /// server are refused (a hostile server must not reach this Mac's agent or X display).
    func testUnrequestedAgentAndX11ChannelsAreRefused() async throws {
        let agent = try TestAgent(directory: sshd.directory, keys: [sshd.keyPath])
        defer { agent.stop() }
        let display = sshd.directory.appendingPathComponent("X0").path
        let x11 = try UnixListener(path: display)
        defer { x11.stop() }
        var o = options(keys: [sshd.keyPath])
        o.agentSocket = agent.socketPath
        o.x11Display = display
        let connection = SSHConnection(options: o, prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        try await connection.connect()
        defer { connection.disconnect() }
        let accepted = try await connection.perform { () -> (Bool, Bool) in
            (connection.acceptAgentChannel() != nil, connection.acceptX11Channel() != nil)
        }
        XCTAssertFalse(accepted.0, "agent channel without agent forwarding")
        XCTAssertFalse(accepted.1, "X11 channel without X11 forwarding")
    }

    func testNoUsableKeyIsRejected() async throws {
        let stranger = sshd.directory.appendingPathComponent("stranger").path
        try TestSSHD.keygen(stranger, passphrase: "")
        let connection = SSHConnection(options: options(keys: [stranger]), prompter: ScriptedPrompter(), passwords: InMemoryPasswordStore())
        do {
            try await connection.connect()
            XCTFail("logged in with a key that is not authorized")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .authenticationRejected)
        }
    }
}

/// Collects a channel's output and waits for it to close.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var status: Int32??
    private let closed = DispatchSemaphore(value: 0)

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    var handlers: SSHChannelHandlers {
        SSHChannelHandlers(
            data: { [self] chunk in lock.withLock { data.append(chunk) } },
            closed: { [self] exitStatus in
                lock.withLock { status = .some(exitStatus) }
                closed.signal()
            })
    }

    func waitForClose(timeout: TimeInterval) async throws -> Int32? {
        let semaphore = closed
        let ok = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success) }
        }
        guard ok else { throw NSError(domain: "OutputCollector", code: 1, userInfo: [NSLocalizedDescriptionKey: "no close; output: \(text)"]) }
        return lock.withLock { status ?? nil }
    }
}

func XCTAssertThrowsErrorAsync(_ body: @autoclosure () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("no error", file: file, line: line)
    } catch {}
}
#endif
