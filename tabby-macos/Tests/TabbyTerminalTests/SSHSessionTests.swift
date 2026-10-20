import XCTest
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbySSH
import TabbyIPC

/// End-to-end tests against a real sshd. They run only when these are set:
///   TABBYMAC_SSH_TEST_PORT, TABBYMAC_SSH_TEST_USER, TABBYMAC_SSH_TEST_PASSWORD,
///   TABBYMAC_ASKPASS (path to the built tabby-askpass binary).
final class SSHSessionTests: XCTestCase, SSHPromptHandler {
    var env: [String: String] { ProcessInfo.processInfo.environment }
    var prompts: [AskpassPrompt] = []
    var replies: [(AskpassPrompt) -> SSHPromptReply] = []

    func sshSession(_ session: SSHSession, needs prompt: AskpassPrompt, reply: @escaping (SSHPromptReply) -> Void) {
        prompts.append(prompt)
        let responder = replies.isEmpty ? { _ in .cancel } : replies.removeFirst()
        reply(responder(prompt))
    }

    struct Setup {
        var session: SSHSession
        var passwords: InMemoryPasswordStore
        var knownHosts: String
        var server: AskpassServer
    }

    func makeSession(password: String?, profileOptions extra: [String: ConfigValue] = [:], jump: ((String) -> SSHOptions?)? = nil) throws -> Setup {
        guard let port = env["TABBYMAC_SSH_TEST_PORT"].flatMap(Int.init), let user = env["TABBYMAC_SSH_TEST_USER"],
              let askpass = env["TABBYMAC_ASKPASS"] else {
            throw XCTSkip("SSH integration environment not configured")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let server = AskpassServer(socketPath: dir.appendingPathComponent("a.sock").path)
        try server.start()
        let store = InMemoryPasswordStore()
        if let password { store.savePassword(password, host: "127.0.0.1", port: port, user: user) }
        let knownHosts = dir.appendingPathComponent("known_hosts").path
        var options: [String: ConfigValue] = ["host": "127.0.0.1", "port": .int(port), "user": .string(user), "auth": "password"]
        for (k, v) in extra { options[k] = v }
        let profile = Profile(id: "ssh:test", type: "ssh", name: "test", options: .object(options))
        let session = SSHSession(
            profile: profile, context: SessionContext(),
            environment: .init(sshPath: PTYProcess.resolveExecutable("ssh", path: env["PATH"]) ?? "/usr/bin/ssh",
                               askpassPath: askpass, server: server, passwords: store,
                               knownHostsFile: knownHosts, userKnownHostsFiles: [], configDirectory: dir.path),
            jumpHostResolver: jump ?? { _ in nil })
        session.promptHandler = self
        return Setup(session: session, passwords: store, knownHosts: knownHosts, server: server)
    }

    func run(_ s: SSHSession, until marker: String, then input: String? = nil, timeout: TimeInterval = 20) -> (String, Int32??) {
        var out = ""
        var exit: Int32?? = .none
        let seen = expectation(description: "marker")
        var fulfilled = false
        s.onOutput = { d in
            out += String(decoding: d, as: UTF8.self)
            if !fulfilled && out.contains(marker) {
                fulfilled = true
                seen.fulfill()
            }
        }
        let closed = expectation(description: "closed")
        s.onClosed = { c in exit = .some(c); closed.fulfill() }
        XCTAssertNoThrow(try s.start(cols: 80, rows: 24))
        wait(for: [seen], timeout: timeout)
        if let input { s.write(Data(input.utf8)) }
        wait(for: [closed], timeout: timeout)
        return (out, exit)
    }

    func testHostKeyPromptThenSavedPassword() throws {
        let setup = try makeSession(password: env["TABBYMAC_SSH_TEST_PASSWORD"])
        replies = [{ prompt in
            if case .hostKey = prompt { return .accept }
            return .cancel
        }]
        let (out, exit) = run(setup.session, until: "$ ", then: "echo TABBY-$((6*7)); exit 7\n")
        XCTAssertTrue(out.contains("TABBY-42"), out)
        XCTAssertEqual(exit, .some(7))
        guard case let .hostKey(_, type, fp, _)? = prompts.first else { return XCTFail("expected host key prompt, got \(prompts)") }
        XCTAssertEqual(type, "ED25519")
        XCTAssertTrue(fp?.hasPrefix("SHA256:") ?? false)
        XCTAssertTrue((try String(contentsOfFile: setup.knownHosts, encoding: .utf8)).contains("ssh-ed25519"), "accepted key was saved")
        XCTAssertTrue(out.contains("Using saved password"))
        XCTAssertTrue(setup.session.isConnected == false)
        setup.server.stop()
    }

    func testPasswordPromptRemembersAfterSuccess() throws {
        let password = try XCTUnwrap(env["TABBYMAC_SSH_TEST_PASSWORD"])
        let setup = try makeSession(password: "wrong-password")
        replies = [
            { if case .hostKey = $0 { return .accept } else { return .cancel } },
            { if case .password = $0 { return .text(password, remember: true) } else { return .cancel } },
        ]
        let (out, exit) = run(setup.session, until: "$ ", then: "exit\n")
        XCTAssertEqual(exit, .some(0), out)
        XCTAssertEqual(prompts.count, 2, "\(prompts)")
        let port = Int(env["TABBYMAC_SSH_TEST_PORT"]!)!
        XCTAssertEqual(setup.passwords.password(host: "127.0.0.1", port: port, user: env["TABBYMAC_SSH_TEST_USER"]!), password,
                       "the wrong saved password was replaced by the remembered one")
        setup.server.stop()
    }

    func testJumpHost() throws {
        let port = try XCTUnwrap(env["TABBYMAC_SSH_TEST_PORT"].flatMap(Int.init))
        let user = try XCTUnwrap(env["TABBYMAC_SSH_TEST_USER"])
        let bastion = SSHOptions(["host": "127.0.0.1", "port": .int(port), "user": .string(user), "auth": "password"])
        let setup = try makeSession(password: env["TABBYMAC_SSH_TEST_PASSWORD"], profileOptions: ["jumpHost": "ssh:bastion"],
                                    jump: { $0 == "ssh:bastion" ? bastion : nil })
        replies = Array(repeating: { if case .hostKey = $0 { return .accept } else { return .cancel } }, count: 2)
        let (out, exit) = run(setup.session, until: "$ ", then: "echo $SSH_CONNECTION; exit\n")
        XCTAssertEqual(exit, .some(0), out)
        XCTAssertTrue(out.contains("127.0.0.1"), out)
        XCTAssertEqual(out.components(separatedBy: "Using saved password").count - 1, 2, "both hops authenticated: \(out)")
        setup.server.stop()
    }

    func testCancelledPromptFailsCleanly() throws {
        let setup = try makeSession(password: nil)
        replies = [{ if case .hostKey = $0 { return .reject } else { return .cancel } }]
        var out = ""
        let closed = expectation(description: "closed")
        var code: Int32?? = .none
        setup.session.onOutput = { out += String(decoding: $0, as: UTF8.self) }
        setup.session.onClosed = { c in code = .some(c); closed.fulfill() }
        try setup.session.start(cols: 80, rows: 24)
        wait(for: [closed], timeout: 20)
        XCTAssertEqual(code, .some(255), out)
        XCTAssertTrue(out.contains("Connection failed"), out)
        setup.server.stop()
    }
}
