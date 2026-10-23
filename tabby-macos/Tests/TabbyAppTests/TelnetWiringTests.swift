#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbyTelnet
import TabbyTerminal
@testable import TabbyApp

/// Telnet profiles are known to the app: provider, session factory, hotkey.
@MainActor
final class TelnetWiringTests: XCTestCase {
    func testTelnetIsWiredIn() async throws {
        TestApp.boot()
        let services = AppServices.shared
        XCTAssertTrue(services.factories["telnet"] is TelnetSessionFactory)
        XCTAssertTrue(services.profiles.provider(for: "telnet") is TelnetProfileProvider)
        let ids = services.profiles.allProfiles().map(\.id)
        XCTAssertTrue(ids.contains("telnet:template"))
        XCTAssertTrue(ids.contains("socket:template"))
        XCTAssertEqual(services.config.value("hotkeys.restart-telnet-session")?.arrayValue?.count, 0)
        XCTAssertNotNil(HotkeyCatalog.byId["restart-telnet-session"])
    }
}
#endif
