#if os(macOS)
import XCTest
import TabbyCore
import TabbySSH
@testable import TabbySSHLib

/// Profiles to connections: sharing (Tabby's reuseSession, in place of ControlMaster),
/// reference counting, and jump hosts through a bridged channel.
@MainActor
final class SSHConnectorTests: XCTestCase {
    var target: TestSSHD!
    var jump: TestSSHD!
    var profiles: [String: Profile] = [:]

    override func setUp() async throws {
        target = try TestSSHD(name: "target")
        jump = try TestSSHD(name: "jump")
    }

    override func tearDown() async throws {
        target.stop()
        jump.stop()
    }

    func profile(_ id: String, sshd: TestSSHD, host: String = "127.0.0.1", reuse: Bool = true, jumpHost: String? = nil) -> Profile {
        var options: [String: ConfigValue] = ["host": .string(host), "port": .int(sshd.port), "user": .string(sshd.user),
                                              "privateKeys": .array([.string(sshd.keyPath)]), "reuseSession": .bool(reuse)]
        if let jumpHost { options["jumpHost"] = .string(jumpHost) }
        let p = Profile(id: id, type: "ssh", name: id, options: .object(options))
        profiles[id] = p
        return p
    }

    func makeConnector() -> SSHConnector {
        let environment = LibSSHSession.Environment(
            knownHostsFile: target.directory.appendingPathComponent("known_hosts").path, globalKnownHostsFile: nil,
            agentSocket: { nil }, homeDirectory: target.directory.path, passwords: InMemoryPasswordStore())
        let connector = SSHConnector(environment: environment)
        connector.resolveProfile = { [unowned self] id in self.profiles[id] }
        return connector
    }

    func testSharedProfilesUseOneConnectionUntilTheLastRelease() async throws {
        let connector = makeConnector()
        let prompter = ScriptedPrompter()
        let p = profile("ssh:a", sshd: target)
        async let first = connector.acquire(profile: p, prompter: prompter)
        async let second = connector.acquire(profile: p, prompter: prompter)
        let (a, b) = try await (first, second)
        XCTAssertTrue(a === b, "one connection for both tabs")
        XCTAssertEqual(prompter.hostKeys.count, 1, "the host key is asked about once")
        connector.release(a)
        XCTAssertTrue(a.isConnected, "still used by the other tab")
        connector.release(b)
        try await waitUntil { !a.isConnected }
        let c = try await connector.acquire(profile: p, prompter: prompter)
        XCTAssertFalse(c === a, "a new connection after the last release")
        connector.release(c)
    }

    func testWithoutReuseEveryTabConnects() async throws {
        let connector = makeConnector()
        let p = profile("ssh:solo", sshd: target, reuse: false)
        let a = try await connector.acquire(profile: p, prompter: ScriptedPrompter())
        let b = try await connector.acquire(profile: p, prompter: ScriptedPrompter())
        XCTAssertFalse(a === b)
        connector.release(a)
        connector.release(b)
    }

    func testAJumpHostCarriesTheConnection() async throws {
        let connector = makeConnector()
        let prompter = ScriptedPrompter()
        _ = profile("ssh:jump", sshd: jump)
        // "localhost" so the target's known_hosts entry differs from the jump's.
        let p = profile("ssh:behind", sshd: target, host: "localhost", jumpHost: "ssh:jump")
        let connection = try await connector.acquire(profile: p, prompter: prompter)
        XCTAssertEqual(prompter.hostKeys.map(\.fingerprint), [jump.hostKeyFingerprint, target.hostKeyFingerprint])
        let output = OutputCollector()
        let shell = try await connection.openShell(term: "xterm", columns: 80, rows: 24, handlers: output.handlers)
        shell.write(Data("echo via-jump; exit\n".utf8))
        _ = try await output.waitForClose(timeout: 10)
        XCTAssertTrue(output.text.contains("via-jump"), output.text)
        XCTAssertEqual(connector.sharedCount, 2, "the jump connection is shared too")
        connector.release(connection)
        try await waitUntil { connector.sharedCount == 0 }
    }

    func testJumpHostLoopsAndMissingJumpHostsAreErrors() async throws {
        let connector = makeConnector()
        _ = profile("ssh:x", sshd: target, jumpHost: "ssh:y")
        let y = profile("ssh:y", sshd: target, jumpHost: "ssh:x")
        do {
            _ = try await connector.acquire(profile: y, prompter: ScriptedPrompter())
            XCTFail("connected through a loop")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .connectFailed("Jump host loop: ssh:y → ssh:x → ssh:y"))
        }
        let lost = profile("ssh:lost", sshd: target, jumpHost: "ssh:gone")
        do {
            _ = try await connector.acquire(profile: lost, prompter: ScriptedPrompter())
            XCTFail("connected through a missing jump host")
        } catch let error as SSHConnectionError {
            XCTAssertEqual(error, .connectFailed("127.0.0.1: jump host \"ssh:gone\" not found in your config"))
        }
    }

    func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "wait", code: 1) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
#endif
