import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 5: Tabby's per-tab "Notify when done" (`TaskCompletionContextMenu`, polled by
/// `CompletionObserver` once a second) and "Notify on activity", both one-shot.
final class NotifyTests: XCTestCase {
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    func pump(until condition: () -> Bool, timeout: Double = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump(0.02) }
    }

    func localPane() throws -> (TerminalPane, FakeSession) {
        let (pane, _, factory) = try makeFakePane(type: "local")
        pane.start()
        pane.completionPollInterval = 0.05
        return (pane, try XCTUnwrap(factory.sessions.first))
    }

    func testNotifyWhenDoneNeedsARunningProcess() throws {
        let (pane, session) = try localPane()
        defer { pane.close() }
        pane.setNotifyWhenDone(true)
        XCTAssertFalse(pane.notifyWhenDone, "nothing to wait for at the prompt")
        session.foregroundProcess = "sleep"
        pane.setNotifyWhenDone(true)
        XCTAssertTrue(pane.notifyWhenDone)
    }

    func testItFiresOnceWhenTheProcessIsGone() throws {
        let (pane, session) = try localPane()
        defer { pane.close() }
        var fired: [String] = []
        pane.onProcessCompleted = { _, name in fired.append(name) }
        session.foregroundProcess = "terraform"
        pane.setNotifyWhenDone(true)
        pump(0.2)
        XCTAssertEqual(fired, [], "still running")
        session.foregroundProcess = nil
        pump(until: { !fired.isEmpty })
        XCTAssertEqual(fired, ["terraform"], "the name of the process it waited for")
        XCTAssertFalse(pane.notifyWhenDone, "one-shot")
        session.foregroundProcess = "vim"
        pump(0.2)
        session.foregroundProcess = nil
        pump(0.2)
        XCTAssertEqual(fired.count, 1)
    }

    func testTurningItOffOrClosingThePaneStopsWatching() throws {
        let (pane, session) = try localPane()
        var fired = 0
        pane.onProcessCompleted = { _, _ in fired += 1 }
        session.foregroundProcess = "sleep"
        pane.setNotifyWhenDone(true)
        pane.setNotifyWhenDone(false)
        session.foregroundProcess = nil
        pump(0.2)
        XCTAssertEqual(fired, 0)
        session.foregroundProcess = "sleep"
        pane.setNotifyWhenDone(true)
        pane.close()
        pump(0.2)
        XCTAssertEqual(fired, 0, "closing by hand is not news")
        XCTAssertFalse(pane.notifyWhenDone)
    }

    /// ★ The session-ended notice already covers a session that ends while armed.
    func testASessionThatEndsWhileArmedOnlyClearsTheFlag() throws {
        let (pane, session) = try localPane()
        defer { pane.close() }
        var fired = 0
        pane.onProcessCompleted = { _, _ in fired += 1 }
        session.foregroundProcess = "sleep"
        pane.setNotifyWhenDone(true)
        session.kill()
        pump(until: { if case .ended = pane.state { return true }; return false })
        pump(0.2)
        XCTAssertFalse(pane.notifyWhenDone)
        XCTAssertEqual(fired, 0)
    }

    func testNotifyOnActivityFiresOnTheNextOutputOnce() throws {
        let (pane, session) = try localPane()
        defer { pane.close() }
        var fired = 0
        pane.onActivityNotification = { _ in fired += 1 }
        session.onOutput?(Data("before\r\n".utf8))
        XCTAssertEqual(fired, 0, "not armed")
        pane.isFocused = true
        pane.setNotifyOnActivity(true)
        XCTAssertTrue(pane.notifyOnActivity)
        session.onOutput?(Data("build finished\r\n".utf8))
        XCTAssertEqual(fired, 1, "the focused pane too, as in Tabby")
        XCTAssertFalse(pane.notifyOnActivity)
        session.onOutput?(Data("more\r\n".utf8))
        XCTAssertEqual(fired, 1)
    }
}
