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

    func start(cols: Int, rows: Int) throws { isRunning = true }
    func write(_ data: Data) {}
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

final class ClosingTests: XCTestCase {
    func makePane(type: String = "ssh", options: [String: ConfigValue] = [:],
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

    func testLocalPaneIgnoresSSHWarnOnClose() throws {
        let (pane, _, _) = try makePane(type: "local")
        pane.start()
        XCTAssertNil(pane.closeWarning(sshWarnOnClose: true))
    }
}
