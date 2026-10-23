import XCTest
import TabbyCore
@testable import TabbyTerminal

/// The profile's Backspace mode applies to what the pane sends.
final class InputProcessingPaneTests: XCTestCase {
    func testBackspaceFollowsTheProfile() throws {
        let (pane, _, factory) = try makeFakePane(options: ["input": ["backspace": "ctrl-h"]])
        pane.startIfNeeded()
        let session = try XCTUnwrap(factory.sessions.first)
        pane.send(Data([0x7f]))
        pane.send(Data("ls".utf8))
        XCTAssertEqual(session.written, [Data([0x08]), Data("ls".utf8)])
    }
}
