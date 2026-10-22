import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// The SSH status chip of the phase 2 design: Connecting…, Connected, Disconnected and
/// Reconnecting n/5. Automatic reconnects stop after five failed attempts.
final class ConnectionStateTests: XCTestCase {

    private func pump(until condition: () -> Bool, timeout: Double = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testLocalPanesHaveNoConnectionState() throws {
        let (pane, _, _) = try makeFakePane(type: "local")
        pane.start()
        XCTAssertNil(pane.connectionState)
    }

    func testStateFollowsTheSessionStatus() throws {
        let (pane, _, factory) = try makeFakePane()
        pane.start()
        let session = try XCTUnwrap(factory.sessions.last)
        session.onStatus?(.connecting("example.org"))
        XCTAssertEqual(pane.connectionState, .connecting)
        session.onStatus?(.connected)
        XCTAssertEqual(pane.connectionState, .connected)
        pane.disconnect()
        pump(until: { pane.connectionState == .disconnected })
        XCTAssertEqual(pane.connectionState, .disconnected)
    }

    func testAutomaticReconnectGivesUpAfterFiveAttempts() throws {
        let (pane, engine, factory) = try makeFakePane(behavior: .reconnect)
        pane.reconnectDelay = 0.05
        pane.start()
        factory.sessions.last?.onStatus?(.connected)
        for attempt in 1...TerminalPane.maxReconnectAttempts {
            factory.sessions.last?.kill()
            pump(until: { pane.connectionState == .reconnecting(attempt: attempt, of: TerminalPane.maxReconnectAttempts) })
            XCTAssertEqual(pane.connectionState, .reconnecting(attempt: attempt, of: TerminalPane.maxReconnectAttempts))
            pump(until: { factory.sessions.count == attempt + 1 })
        }
        XCTAssertEqual(factory.sessions.count, 6)
        factory.sessions.last?.kill()
        pump(until: { pane.connectionState == .disconnected })
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(factory.sessions.count, 6, "no sixth reconnect")
        XCTAssertEqual(pane.connectionState, .disconnected)
        XCTAssertEqual(pane.state, .ended(code: nil, canRestart: true))
        XCTAssertTrue(engine.text.contains("Press any key"))
        pane.close()
    }

    func testConnectingAgainResetsTheAttempts() throws {
        let (pane, _, factory) = try makeFakePane(behavior: .reconnect)
        pane.reconnectDelay = 0.05
        pane.start()
        factory.sessions.last?.kill()
        pump(until: { factory.sessions.count == 2 })
        factory.sessions.last?.onStatus?(.connected)
        XCTAssertEqual(pane.connectionState, .connected)
        factory.sessions.last?.kill()
        pump(until: { pane.connectionState != .connected })
        XCTAssertEqual(pane.connectionState, .reconnecting(attempt: 1, of: TerminalPane.maxReconnectAttempts))
        pane.close()
    }
}

/// What the "Process completed" toast reports.
final class ProcessEndedTests: XCTestCase {

    func testClosingAPaneByHandDoesNotReportTheProcessEnded() throws {
        let (pane, _, _) = try makeFakePane(type: "local")
        var reported = false
        pane.onProcessEnded = { _, _ in reported = true }
        pane.start()
        pane.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertFalse(reported)
    }

    func testAProcessThatEndsOnItsOwnIsReportedWithItsRunningTime() throws {
        let (pane, _, factory) = try makeFakePane(type: "local")
        var reported = false
        pane.onProcessEnded = { _, _ in reported = true }
        pane.start()
        let started = try XCTUnwrap(pane.startedAt)
        XCTAssertLessThan(abs(started.timeIntervalSinceNow), 2)
        factory.sessions.last?.kill()
        let deadline = Date().addingTimeInterval(2)
        while !reported, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(reported)
    }
}
