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
