import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// A raw connection the way serial and telnet sessions look to `ProcessedSession`: output,
/// service lines that must not be processed, and the peer's echo requests.
final class RawConnectionFake: TerminalSession, ServiceOutputSource, LocalEchoSource {
    var onOutput: ((Data) -> Void)?
    var onClosed: ((Int32?) -> Void)?
    var onStatus: ((SessionStatus) -> Void)?
    var onServiceOutput: ((Data) -> Void)?
    var onLocalEchoChanged: ((Bool) -> Void)?
    private(set) var isRunning = false
    private(set) var written = Data()
    private(set) var size: (cols: Int, rows: Int)?
    private(set) var killed = false

    func start(cols: Int, rows: Int) throws {
        isRunning = true
        size = (cols, rows)
    }
    func write(_ data: Data) { written.append(data) }
    func resize(cols: Int, rows: Int) { size = (cols, rows) }
    func kill() { killed = true }
    func workingDirectory() -> String? { nil }
}

final class ProcessedSessionTests: XCTestCase {
    private func make(_ options: [String: ConfigValue]) -> (ProcessedSession, RawConnectionFake, () -> String) {
        let raw = RawConnectionFake()
        let session = ProcessedSession(inner: raw, options: StreamOptions(.object(options)))
        session.settleDelay = 0.05
        var shown = Data()
        session.onOutput = { shown.append($0) }
        return (session, raw, { String(decoding: shown, as: UTF8.self) })
    }

    func testOutputAndInputGoThroughTheProcessor() throws {
        let (session, raw, shown) = make(["outputNewlines": "crlf", "inputMode": "local-echo", "inputNewlines": "lf"])
        try session.start(cols: 80, rows: 24)
        raw.onOutput?(Data("a\nb".utf8))
        XCTAssertEqual(shown(), "a\r\nb")
        session.write(Data("x\r".utf8))
        XCTAssertEqual(String(decoding: raw.written, as: UTF8.self), "x\n")
        XCTAssertEqual(shown(), "a\r\nbx\r\n")
    }

    func testServiceLinesAreNotProcessed() throws {
        let (session, raw, shown) = make(["outputMode": "hex"])
        try session.start(cols: 80, rows: 24)
        raw.onServiceOutput?(ServiceMessage.line("Port opened", badge: .serial))
        XCTAssertEqual(shown(), String(decoding: ServiceMessage.line("Port opened", badge: .serial), as: UTF8.self))
    }

    func testThePromptAppearsWhenOutputSettlesAndMakesWayForServiceLines() throws {
        let (session, raw, shown) = make(["inputMode": "readline"])
        try session.start(cols: 80, rows: 24)
        let prompt = expectation(description: "prompt")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { prompt.fulfill() }
        wait(for: [prompt], timeout: 2)
        XCTAssertEqual(shown(), "\r\n> ")
        raw.onServiceOutput?(Data("closed\r\n".utf8))
        XCTAssertEqual(shown(), "\r\n> \u{1b}[2K\rclosed\r\n")
    }

    func testThePeerCanTurnOnLocalEcho() throws {
        let (session, raw, shown) = make([:])
        try session.start(cols: 80, rows: 24)
        session.write(Data("a".utf8))
        XCTAssertEqual(shown(), "")
        raw.onLocalEchoChanged?(true)
        session.write(Data("b".utf8))
        XCTAssertEqual(shown(), "b")
        XCTAssertEqual(String(decoding: raw.written, as: UTF8.self), "ab")
    }

    func testLifecyclePassesThrough() throws {
        let (session, raw, _) = make([:])
        var statuses: [SessionStatus] = []
        var closed: [Int32?] = []
        session.onStatus = { statuses.append($0) }
        session.onClosed = { closed.append($0) }
        try session.start(cols: 100, rows: 30)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(raw.size?.cols, 100)
        session.resize(cols: 90, rows: 20)
        XCTAssertEqual(raw.size?.rows, 20)
        raw.onStatus?(.connected)
        raw.onClosed?(3)
        XCTAssertEqual(statuses, [.connected])
        XCTAssertEqual(closed, [3])
        session.kill()
        XCTAssertTrue(raw.killed)
        XCTAssertTrue(session.inner === raw)
    }
}

/// Behaviour every connection type now shares with SSH: login scripts and clearing the
/// service messages once connected.
final class ConnectionPaneTests: XCTestCase {
    private func scripts(_ list: [[String: ConfigValue]]) -> [String: ConfigValue] {
        ["scripts": .array(list.map { .object($0) })]
    }

    func testLoginScriptsRunForEveryType() throws {
        for type in ["serial", "telnet", "local"] {
            let (pane, _, factory) = try makeFakePane(type: type, options: scripts([["expect": "login:", "send": "root"]]))
            pane.start()
            factory.sessions[0].onOutput?(Data("login:".utf8))
            XCTAssertEqual(factory.sessions[0].written.map { String(decoding: $0, as: UTF8.self) }, ["root\n"], type)
        }
    }

    func testAConnectionClearsItsServiceMessagesWhenTheProfileSaysSo() throws {
        let (pane, engine, factory) = try makeFakePane(type: "telnet")
        var profile = pane.profile
        profile.clearServiceMessagesOnConnect = true
        pane.switchProfile(profile)
        factory.sessions.last!.onOutput?(Data("Connecting".utf8))
        factory.sessions.last!.onStatus?(.connected)
        XCTAssertEqual(engine.cleared, 1)
        XCTAssertEqual(factory.sessions.last!.written, [], "clearing sends nothing to the peer (no ^L)")
    }

    func testAConnectionKeepsItsServiceMessagesByDefault() throws {
        let (pane, engine, factory) = try makeFakePane(type: "serial")
        pane.start()
        factory.sessions[0].onStatus?(.connected)
        XCTAssertEqual(engine.cleared, 0)
    }

    func testARestoredPaneKeepsItsScrollbackOnItsFirstConnect() throws {
        let profile = Profile(id: "ssh:test", type: "ssh", name: "test", options: ["host": "h"])
        let factory = FakeSessionFactory(profileType: "ssh")
        let settings = TerminalSettings(config: ConfigStore(defaults: try ConfigStore.bundledDefaults()))
        let restore = PaneRecovery(type: "app:ssh-tab", profile: profile, savedState: "old output")
        let pane = TerminalPane(profile: profile, factory: factory, context: SessionContext(),
                                settings: settings, scheme: .tabbyDefault, restore: restore)
        let engine = FakeEngine()
        pane.attach(engine: engine)
        pane.start()
        factory.sessions[0].onStatus?(.connected)
        XCTAssertEqual(engine.cleared, 0)
        pane.restart()
        factory.sessions[1].onStatus?(.connected)
        XCTAssertEqual(engine.cleared, 1, "a reconnect clears as usual")
    }

    // Tabby's serial and telnet tabs count `close` or `quit` as ending the session on
    // purpose; SSH keeps exit / logout / ^D.
    func testAutoClosesASerialOrTelnetTabOnCloseOrQuit() throws {
        let cases: [(String, String, Bool)] = [
            ("telnet", "quit\r", true), ("serial", "close\r", true), ("telnet", "exit\r", false),
            ("ssh", "exit\r", true), ("ssh", "quit\r", false),
        ]
        for (type, input, closes) in cases {
            let (pane, _, factory) = try makeFakePane(type: type)
            var closeRequested = false
            pane.onRequestClose = { _ in closeRequested = true }
            pane.start()
            pane.send(text: input)
            factory.sessions[0].onClosed?(nil)
            XCTAssertEqual(closeRequested, closes, "\(type) \(input)")
        }
    }

    // Tabby's `TelnetTabComponent.canClose`; serial tabs never ask.
    func testATelnetPaneAsksBeforeClosingWhileConnected() throws {
        let (telnet, _, _) = try makeFakePane(type: "telnet")
        XCTAssertNil(telnet.closeWarning(sshWarnOnClose: false), "not started")
        telnet.start()
        XCTAssertEqual(telnet.closeWarning(sshWarnOnClose: false), "Disconnect from example.org?")
        let (serial, _, _) = try makeFakePane(type: "serial")
        serial.start()
        XCTAssertNil(serial.closeWarning(sshWarnOnClose: true))
    }

    // A session that ends inside `start` (a port that can't open) leaves the pane ended and
    // ready to retry, not running.
    func testASessionThatEndsWhileStartingLeavesThePaneEnded() throws {
        final class EndsAtOnce: TerminalSession {
            var onOutput: ((Data) -> Void)?
            var onClosed: ((Int32?) -> Void)?
            var onStatus: ((SessionStatus) -> Void)?
            var isRunning = false
            func start(cols: Int, rows: Int) throws { onClosed?(nil) }
            func write(_ data: Data) {}
            func resize(cols: Int, rows: Int) {}
            func kill() {}
            func workingDirectory() -> String? { nil }
        }
        final class Factory: SessionFactory {
            let profileType = "serial"
            func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession { EndsAtOnce() }
        }
        let settings = TerminalSettings(config: ConfigStore(defaults: try ConfigStore.bundledDefaults()))
        let pane = TerminalPane(profile: Profile(type: "serial", name: "s"), factory: Factory(), context: SessionContext(),
                                settings: settings, scheme: .tabbyDefault)
        pane.attach(engine: FakeEngine())
        pane.start()
        XCTAssertEqual(pane.state, .ended(code: nil, canRestart: true))
    }
}
