#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbySSHLib
import TabbyTerminal
@testable import TabbyApp

/// SSH profiles open on the library backend unless `ssh.backend` says otherwise.
@MainActor
final class SSHBackendWiringTests: XCTestCase {
    func testSSHProfilesUseTheBackendSwitch() async throws {
        TestApp.boot()
        let services = AppServices.shared
        let factory = try XCTUnwrap(services.factories["ssh"] as? SSHBackendFactory)
        XCTAssertEqual(services.config.value("ssh.backend")?.stringValue, "library")
        let profile = Profile(id: "ssh:w", type: "ssh", name: "w", options: ["host": "example.org"])
        XCTAssertTrue(try factory.makeSession(profile: profile, context: SessionContext()) is LibSSHSession)
        services.config.set("ssh.backend", "openssh")
        defer { services.config.set("ssh.backend", nil) }
        XCTAssertFalse(try factory.makeSession(profile: profile, context: SessionContext()) is LibSSHSession)
    }
}
#endif
