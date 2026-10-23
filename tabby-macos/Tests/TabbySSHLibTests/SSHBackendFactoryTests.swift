#if os(macOS)
import XCTest
import TabbyCore
import TabbySSH
import TabbyTerminal
@testable import TabbySSHLib

/// `ssh.backend` picks the SSH implementation; a profile's `backend` option overrides it.
final class SSHBackendFactoryTests: XCTestCase {
    func makeFactory(global: String?) -> SSHBackendFactory {
        let passwords = InMemoryPasswordStore()
        let dir = FileManager.default.temporaryDirectory.path
        let openSSH = SSHSessionFactory(
            environment: SSHSession.Environment(askpassPath: "/usr/bin/true", server: AskpassServer(socketPath: dir + "/unused.sock"),
                                                passwords: passwords, knownHostsFile: dir + "/kh"),
            resolveProfile: { _ in nil })
        let library = LibSSHSessionFactory(environment: LibSSHSession.Environment(knownHostsFile: dir + "/kh", passwords: passwords))
        return SSHBackendFactory(openSSH: openSSH, library: library, configuredBackend: { global })
    }

    func profile(backend: String? = nil) -> Profile {
        var options: [String: ConfigValue] = ["host": "example.org"]
        if let backend { options["backend"] = .string(backend) }
        return Profile(id: "ssh:x", type: "ssh", name: "x", options: .object(options))
    }

    func testTheLibraryIsTheDefault() throws {
        XCTAssertTrue(try makeFactory(global: nil).makeSession(profile: profile(), context: SessionContext()) is LibSSHSession)
        XCTAssertTrue(try makeFactory(global: "library").makeSession(profile: profile(), context: SessionContext()) is LibSSHSession)
    }

    func testOpenSSHCanBeChosenGloballyOrPerProfile() throws {
        XCTAssertTrue(try makeFactory(global: "openssh").makeSession(profile: profile(), context: SessionContext()) is SSHSession)
        XCTAssertTrue(try makeFactory(global: nil).makeSession(profile: profile(backend: "openssh"), context: SessionContext()) is SSHSession)
        XCTAssertTrue(try makeFactory(global: "openssh").makeSession(profile: profile(backend: "library"), context: SessionContext()) is LibSSHSession)
        XCTAssertTrue(try makeFactory(global: "nonsense").makeSession(profile: profile(), context: SessionContext()) is LibSSHSession,
                      "an unknown value means the default")
    }
}
#endif
