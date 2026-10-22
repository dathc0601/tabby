import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// An in-memory session: `kill()` ends it the way a PTY child exiting would.
final class FakeSession: TerminalSession {
    var onOutput: ((Data) -> Void)?
    var onClosed: ((Int32?) -> Void)?
    var onStatus: ((SessionStatus) -> Void)?
    private(set) var isRunning = false
    private(set) var killCount = 0
    private(set) var written: [Data] = []

    func start(cols: Int, rows: Int) throws { isRunning = true }
    func write(_ data: Data) { written.append(data) }
    func resize(cols: Int, rows: Int) {}
    func kill() {
        killCount += 1
        guard isRunning else { return }
        isRunning = false
        DispatchQueue.main.async { self.onClosed?(nil) }
    }
    func workingDirectory() -> String? { nil }
}

final class FakeSessionFactory: SessionFactory {
    let profileType: String
    private(set) var sessions: [FakeSession] = []
    init(profileType: String) { self.profileType = profileType }
    func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        let s = FakeSession()
        sessions.append(s)
        return s
    }
}

/// A pane over `FakeSession`s (shared by the closing and connection-state tests; Linux's
/// XCTest has no `init()` to borrow another test case's helpers).
func makeFakePane(type: String = "ssh", options: [String: ConfigValue] = [:],
                  behavior: SessionEndBehavior = .auto) throws -> (TerminalPane, FakeEngine, FakeSessionFactory) {
    var opts: [String: ConfigValue] = ["host": .string("example.org"), "user": .string("me")]
    opts.merge(options) { _, new in new }
    let profile = Profile(id: "\(type):test", type: type, name: "test", options: .object(opts),
                          behaviorOnSessionEnd: behavior)
    let factory = FakeSessionFactory(profileType: type)
    let settings = TerminalSettings(config: ConfigStore(defaults: try ConfigStore.bundledDefaults()))
    let pane = TerminalPane(profile: profile, factory: factory, context: SessionContext(),
                            settings: settings, scheme: .tabbyDefault)
    let engine = FakeEngine()
    pane.attach(engine: engine)
    return (pane, engine, factory)
}

final class ClosingTests: XCTestCase {
    func makePane(type: String = "ssh", options: [String: ConfigValue] = [:],
                  behavior: SessionEndBehavior = .auto) throws -> (TerminalPane, FakeEngine, FakeSessionFactory) {
        try makeFakePane(type: type, options: options, behavior: behavior)
    }

    // MARK: warnOnClose (Tabby `SSHTabComponent.canClose`)

    func testConnectedSSHPaneWarnsWhenGlobalSettingIsOn() throws {
        let (pane, _, _) = try makePane()
        pane.start()
        XCTAssertEqual(pane.closeWarning(sshWarnOnClose: true), "Disconnect from example.org?")
        XCTAssertNil(pane.closeWarning(sshWarnOnClose: false))
    }

    func testProfileWarnOnCloseOverridesGlobalSetting() throws {
        let (off, _, _) = try makePane(options: ["warnOnClose": .bool(false)])
        off.start()
        XCTAssertNil(off.closeWarning(sshWarnOnClose: true))
        let (on, _, _) = try makePane(options: ["warnOnClose": .bool(true)])
        on.start()
        XCTAssertNotNil(on.closeWarning(sshWarnOnClose: false))
    }

    func testSSHPaneThatIsNotConnectedDoesNotWarn() throws {
        let (pane, _, _) = try makePane()
        XCTAssertNil(pane.closeWarning(sshWarnOnClose: true), "never started")
    }

    // MARK: disconnect-tab (Tabby `ConnectableTerminalTabComponent.disconnect`)

    func waitForEnded(_ pane: TerminalPane) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .ended = pane.state { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    func testDisconnectKeepsThePaneAndOffersToReconnect() throws {
        for behavior in [SessionEndBehavior.auto, .close, .reconnect] {
            let (pane, engine, factory) = try makePane(behavior: behavior)
            var closeRequested = false
            pane.onRequestClose = { _ in closeRequested = true }
            pane.start()
            pane.disconnect()
            waitForEnded(pane)
            RunLoop.main.run(until: Date().addingTimeInterval(1.3))
            XCTAssertEqual(pane.state, .ended(code: nil, canRestart: true), "\(behavior)")
            XCTAssertFalse(closeRequested, "\(behavior): a manual disconnect never closes the tab")
            XCTAssertEqual(factory.sessions.count, 1, "\(behavior): no automatic reconnect")
            XCTAssertTrue(engine.text.contains("Press any key"), "\(behavior)")
            pane.send(text: "x")
            XCTAssertEqual(pane.state, .running, "\(behavior): any key reconnects")
            XCTAssertEqual(factory.sessions.count, 2)
            pane.close()
        }
    }

    /// Same as above over a real PTY child: SIGHUP, the waiter thread and `onClosed` on main.
    func testDisconnectOverARealProcessKeepsThePane() throws {
        let profile = Profile(id: "ssh:pty", type: "ssh", name: "pty",
                              options: LocalOptions(command: "/bin/sleep", args: ["30"]).configValue,
                              behaviorOnSessionEnd: .close)
        let settings = TerminalSettings(config: ConfigStore(defaults: try ConfigStore.bundledDefaults()))
        let pane = TerminalPane(profile: profile, factory: LocalSessionFactory(), context: SessionContext(),
                                settings: settings, scheme: .tabbyDefault)
        let engine = FakeEngine()
        pane.attach(engine: engine)
        var closeRequested = false
        pane.onRequestClose = { _ in closeRequested = true }
        pane.start()
        XCTAssertEqual(pane.state, .running)
        pane.disconnect()
        waitForEnded(pane)
        guard case .ended(_, true) = pane.state else { return XCTFail("state \(pane.state)") }
        XCTAssertFalse(closeRequested)
        XCTAssertTrue(engine.text.contains("Press any key"))
        pane.close()
    }

    func testDisconnectIgnoresLocalShells() throws {
        let (pane, _, factory) = try makePane(type: "local")
        pane.start()
        pane.disconnect()
        XCTAssertEqual(pane.state, .running)
        XCTAssertEqual(factory.sessions.first?.killCount, 0)
        pane.close()
    }

    // MARK: process-completed notification

    /// The pane keeps focus when the user switches to another app, so the app (which knows
    /// whether it is active) must hear about every session end, focused pane or not.
    func testSessionEndIsReportedEvenWhenThePaneHasFocus() throws {
        let (pane, _, factory) = try makePane(behavior: .keep)
        var reported = false
        pane.onProcessEnded = { _, _ in reported = true }
        pane.isFocused = true
        pane.start()
        factory.sessions.first?.kill()
        waitForEnded(pane)
        XCTAssertTrue(reported)
    }

    func testLocalPaneIgnoresSSHWarnOnClose() throws {
        let (pane, _, _) = try makePane(type: "local")
        pane.start()
        XCTAssertNil(pane.closeWarning(sshWarnOnClose: true))
    }
}
