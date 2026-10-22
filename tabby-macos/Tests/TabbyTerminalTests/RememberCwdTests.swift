import XCTest
import TabbyCore
@testable import TabbyTerminal

/// Tabby's rememberCwd: an SSH tab reopens in the folder its shell last reported (OSC 7).
final class RememberCwdTests: XCTestCase {
    func testAnSSHTabRemembersItsFolderWhenAsked() throws {
        let (pane, engine, _) = try makeFakePane(options: ["rememberCwd": true])
        pane.startIfNeeded()
        pane.engine(engine, directoryChanged: "file://prod/srv/app")
        let state = pane.recoveryState(includeBuffer: false)
        XCTAssertEqual(state.profile.options["cwd"]?.stringValue, "/srv/app")
    }

    func testWithoutRememberCwdTheProfileKeepsItsOwnFolder() throws {
        let (pane, engine, _) = try makeFakePane(options: ["cwd": "/home/me"])
        pane.startIfNeeded()
        pane.engine(engine, directoryChanged: "file://prod/srv/app")
        XCTAssertEqual(pane.recoveryState(includeBuffer: false).profile.options["cwd"]?.stringValue, "/home/me")
    }
}
