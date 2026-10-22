import XCTest
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbySSH
import TabbyIPC

/// `SSHSession` behaviour that needs no sshd: `ssh` is a stand-in shell script.
final class SSHSessionLocalTests: XCTestCase, SSHPromptHandler {
    var reply: SSHPromptReply = .cancel

    func sshSession(_ session: SSHSession, needs prompt: AskpassPrompt, reply: @escaping (SSHPromptReply) -> Void) {
        reply(self.reply)
    }

    /// A session whose `ssh` runs `script`; `ssh -O check` (the ControlMaster probe) answers `master`.
    func makeSession(master: Bool = false, script: String) throws -> SSHSession {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tm-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ssh = dir.appendingPathComponent("ssh")
        let check = "case \"$*\" in *\"-O check\"*) exit \(master ? 0 : 255);; esac\n"
        try Data(("#!/bin/sh\n" + check + script + "\n").utf8).write(to: ssh)
        chmod(ssh.path, 0o755)
        let server = AskpassServer(socketPath: dir.appendingPathComponent("a.sock").path)
        try server.start()
        addTeardownBlock {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let profile = Profile(id: "ssh:local", type: "ssh", name: "local", options: ["host": "example.org", "user": "me"])
        let session = SSHSession(
            profile: profile, context: SessionContext(),
            environment: .init(sshPath: ssh.path, askpassPath: "/usr/bin/true", server: server, passwords: InMemoryPasswordStore(),
                               knownHostsFile: dir.appendingPathComponent("known_hosts").path, userKnownHostsFiles: [],
                               configDirectory: dir.path),
            jumpHostResolver: { _ in nil })
        session.promptHandler = self
        return session
    }

    /// Starts the session, runs `during` once the output shows `marker` (right away without
    /// one), and returns the output when the session closes.
    func output(of session: SSHSession, after marker: String? = nil, during: () -> Void = {}) throws -> String {
        var out = ""
        let ready = expectation(description: "ready")
        if marker == nil { ready.fulfill() }
        session.onOutput = { data in
            out += String(decoding: data, as: UTF8.self)
            if let marker, out.contains(marker), !out.dropLast(String(decoding: data, as: UTF8.self).count).contains(marker) {
                ready.fulfill()
            }
        }
        let closed = expectation(description: "closed")
        session.onClosed = { _ in closed.fulfill() }
        try session.start(cols: 80, rows: 24)
        wait(for: [ready], timeout: 5)
        during()
        wait(for: [closed], timeout: 5)
        return out
    }

    /// Cancelling a password prompt ends the attempt. Answering ssh's askpass with a failure
    /// made it send an empty password, which the server counts as a failed login; Tabby skips
    /// the method instead. Like real ssh waiting for askpass, the stand-in ignores SIGHUP.
    func testCancelledPasswordPromptEndsTheConnection() throws {
        let session = try makeSession(script: "trap '' HUP\necho ready\nexec sleep 30")
        reply = .cancel
        var answer: AskpassResponse?
        let out = try output(of: session, after: "ready") {
            session.handle(AskpassRequest(kind: .prompt, session: "", token: "", prompt: "me@example.org's password: ")) { answer = $0 }
        }
        XCTAssertEqual(answer?.ok, false)
        XCTAssertTrue(out.contains("Authentication cancelled"), out)
        XCTAssertFalse(out.contains("Connection failed"), out)
    }

    /// A tab that joins a running ControlMaster connection never runs `LocalCommand`, so it
    /// must not call its normal end ("Shared connection … closed", status 255) a failure.
    func testSessionOnARunningMasterIsNotAFailedConnection() throws {
        let session = try makeSession(master: true, script: "echo 'Shared connection to example.org closed.'; exit 255")
        let out = try output(of: session)
        XCTAssertTrue(out.contains("Shared connection"), out)
        XCTAssertFalse(out.contains("Connection failed"), out)
    }

    func testSessionWithoutAMasterStillReportsAFailedConnection() throws {
        let session = try makeSession(master: false, script: "echo 'ssh: connect to host example.org port 22: Connection refused'; exit 255")
        let out = try output(of: session)
        XCTAssertTrue(out.contains("Connection failed"), out)
    }
}
