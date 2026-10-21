import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// A headless stand-in for SwiftTermEngine.
final class FakeEngine: TerminalEngine {
    weak var engineDelegate: TerminalEngineDelegate?
    var gridSize: (cols: Int, rows: Int) = (80, 24)
    var isAlternateScreen = false
    var isBracketedPasteMode = false
    var hasSelection = false
    var output = Data()
    var onFeed: (() -> Void)?

    func feed(_ data: Data) { output.append(data); onFeed?() }
    var text: String { String(decoding: output, as: UTF8.self) }
    func selectedText() -> String? { nil }
    func selectAll() {}
    func clearSelection() {}
    func clearBuffer() { output = Data() }
    func snapshotText(maxLines: Int) -> String { text }
    func scroll(_ action: TerminalScrollAction) {}
    func apply(settings: TerminalSettings, scheme: ColorScheme, fontSize: Double) {}
    func focus() {}
    func find(_ query: String, options: TerminalSearchOptions, backwards: Bool) -> Bool { text.contains(query) }
    func searchSummary(_ query: String, options: TerminalSearchOptions) -> (index: Int, total: Int) { (0, 0) }
    func clearSearch() {}
}

/// The temporary directory with every symlink resolved, as the kernel reports it for a
/// process cwd. On macOS `URL.resolvingSymlinksInPath()` keeps `/var/...` while
/// `proc_pidinfo` returns `/private/var/...`, so use `realpath(3)` instead.
func canonicalTemporaryDirectory() -> String {
    let path = FileManager.default.temporaryDirectory.path
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

final class PTYTests: XCTestCase {
    func testSpawnEchoAndExitCode() throws {
        let env = SessionEnvironment.make(overrides: ["FOO": "bar"])
        let p = PTYProcess(executable: "sh", arguments: ["-c", "printf \"$TERM $COLORTERM $FOO\"; stty size; exit 3"], environment: env)
        var out = Data()
        let exited = expectation(description: "exit")
        var code: Int32?? = .none
        p.onData = { out.append($0) }
        p.onExit = { c in code = .some(c); exited.fulfill() }
        try p.start(cols: 100, rows: 30)
        XCTAssertGreaterThan(p.pid, 0)
        wait(for: [exited], timeout: 10)
        let text = String(decoding: out, as: UTF8.self)
        XCTAssertTrue(text.contains("xterm-256color truecolor bar"), text)
        XCTAssertTrue(text.contains("30 100"), "initial window size is applied: \(text)")
        XCTAssertEqual(code, .some(3))
        XCTAssertFalse(p.isRunning)
    }

    func testWriteResizeAndCwd() throws {
        let dir = canonicalTemporaryDirectory()
        let p = PTYProcess(executable: "/bin/sh", arguments: [], environment: SessionEnvironment.make(overrides: ["PS1": "$ "]), workingDirectory: dir)
        var out = ""
        var sawSize = false
        let gotSize = expectation(description: "size")
        let exited = expectation(description: "exit")
        p.onData = { d in
            out += String(decoding: d, as: UTF8.self)
            // Output arrives in several chunks; only fulfil once.
            if !sawSize, out.contains("40 120") { sawSize = true; gotSize.fulfill() }
        }
        p.onExit = { _ in exited.fulfill() }
        try p.start(cols: 80, rows: 24)
        // The child chdirs right after fork. Until it has exec'd, the requested directory
        // is reported; afterwards the kernel's answer must agree with it.
        XCTAssertEqual(p.currentWorkingDirectory(), dir, "requested cwd before exec")
        let deadline = Date().addingTimeInterval(3)
        while !p.hasExeced && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertTrue(p.hasExeced)
        XCTAssertNil(p.launchFailureErrno)
        XCTAssertEqual(p.currentWorkingDirectory(), dir, "live cwd after exec")
        p.resize(cols: 120, rows: 40)
        p.write(Data("stty size\n".utf8))
        wait(for: [gotSize], timeout: 10)
        p.write(Data("exit\n".utf8))
        wait(for: [exited], timeout: 10)
    }

    func testSignalTerminates() throws {
        let p = PTYProcess(executable: "/bin/sh", arguments: ["-c", "sleep 30"], environment: SessionEnvironment.make())
        let exited = expectation(description: "exit")
        var code: Int32? = 0
        p.onExit = { c in code = c; exited.fulfill() }
        try p.start(cols: 80, rows: 24)
        p.terminate()
        wait(for: [exited], timeout: 10)
        XCTAssertNil(code, "killed by a signal")
    }

    /// Closing a tab releases the PTYProcess while output chunks are still queued on the main
    /// queue. The in-flight semaphore must end up balanced or DispatchSemaphore's dispose traps.
    func testReleasingProcessWithQueuedOutputDoesNotCrash() throws {
        var p: PTYProcess? = PTYProcess(executable: "/usr/bin/yes", arguments: [], environment: SessionEnvironment.make())
        var chunks = 0
        p?.onData = { _ in chunks += 1 }
        try p?.start(cols: 80, rows: 24)
        // Let output flow for a moment: `yes` fills the back-pressure window faster than the
        // main queue drains it, so blocks are queued when the process is released below.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertGreaterThan(chunks, 0, "output reached the main queue while the process was alive")
        p?.terminate(signal: SIGKILL)
        p = nil
        // Drain the main queue: the queued blocks run (and signal) after the process is gone.
        // Before the fix this run loop pass trapped in _dispatch_semaphore_dispose.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    func testMissingExecutable() {
        let p = PTYProcess(executable: "definitely-not-a-command-xyz", arguments: [], environment: [:])
        XCTAssertThrowsError(try p.start(cols: 80, rows: 24))
    }

    func testResolveExecutable() {
        XCTAssertEqual(PTYProcess.resolveExecutable("sh", path: "/nonexistent:/bin"), "/bin/sh")
        XCTAssertNil(PTYProcess.resolveExecutable("sh", path: "/nonexistent"))
    }
}

final class PaneTests: XCTestCase {
    func settings(_ tweak: (inout ConfigStore) -> Void = { _ in }) throws -> TerminalSettings {
        var store = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        tweak(&store)
        return TerminalSettings(config: store)
    }

    func makePane(command: String, args: [String], behavior: SessionEndBehavior = .auto, settings: TerminalSettings? = nil) throws -> (TerminalPane, FakeEngine) {
        let profile = Profile(id: "local:test", type: "local", name: "test",
                              options: LocalOptions(command: command, args: args).configValue, behaviorOnSessionEnd: behavior)
        let pane = TerminalPane(profile: profile, factory: LocalSessionFactory(), context: SessionContext(),
                                settings: try settings ?? self.settings(), scheme: .tabbyDefault)
        let engine = FakeEngine()
        pane.attach(engine: engine)
        return (pane, engine)
    }

    func testRunsAndClosesOnExit() throws {
        let (pane, engine) = try makePane(command: "/bin/sh", args: ["-c", "echo hello; echo 42%"])
        let closed = expectation(description: "close requested")
        pane.onRequestClose = { _ in closed.fulfill() }
        pane.start()
        XCTAssertEqual(pane.state, .running)
        wait(for: [closed], timeout: 10)
        XCTAssertTrue(engine.text.contains("hello"))
        XCTAssertEqual(pane.title, "test")
    }

    func testKeepShowsRestartHintAndRestarts() throws {
        let (pane, engine) = try makePane(command: "/bin/sh", args: ["-c", "exit 2"], behavior: .keep)
        let ended = expectation(description: "ended")
        engine.onFeed = { if engine.text.contains("Press any key") { ended.fulfill(); engine.onFeed = nil } }
        pane.start()
        wait(for: [ended], timeout: 10)
        XCTAssertEqual(pane.state, .ended(code: 2, canRestart: true))
        XCTAssertTrue(engine.text.contains("exited with code 2"))
        pane.send(text: "x")
        XCTAssertEqual(pane.state, .running, "any key restarts")
        pane.close()
    }

    func testProgressDetection() throws {
        let (pane, _) = try makePane(command: "/bin/sh", args: ["-c", "printf 'Downloading 37%%\\n'; sleep 2"], behavior: .keep)
        pane.start()
        let deadline = Date().addingTimeInterval(5)
        while pane.progress == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(pane.progress, 37)
        pane.close()
    }

    func testPasteWarningAndBracketing() throws {
        let (pane, engine) = try makePane(command: "/bin/cat", args: [], behavior: .keep)
        var asked: String?
        pane.onRequestPasteConfirmation = { _, text in asked = text }
        pane.start()
        pane.paste("  echo one\necho two  \n")
        XCTAssertEqual(asked, "echo one\recho two", "trimmed, newlines become CR")
        XCTAssertEqual(pane.pendingPaste, "echo one\recho two")
        pane.cancelPaste()
        XCTAssertNil(pane.pendingPaste)
        engine.isBracketedPasteMode = true
        let echoed = expectation(description: "echo")
        engine.onFeed = { if engine.text.contains("[200~single^[[201~") || engine.text.contains("[200~single\u{1b}[201~") { echoed.fulfill(); engine.onFeed = nil } }
        pane.paste("single")
        wait(for: [echoed], timeout: 10)
        pane.close()
    }

    func testRecoveryStateCarriesCwd() throws {
        let dir = canonicalTemporaryDirectory()
        let profile = Profile(id: "local:x", type: "local", name: "x", options: LocalOptions(command: "/bin/sh", args: []).configValue)
        let pane = TerminalPane(profile: profile, factory: LocalSessionFactory(), context: SessionContext(workingDirectory: dir),
                                settings: try settings(), scheme: .tabbyDefault,
                                restore: PaneRecovery(type: "app:local-tab", profile: profile, savedState: "old line\nsecond", customTitle: "Mine"))
        let engine = FakeEngine()
        pane.attach(engine: engine)
        XCTAssertTrue(engine.text.hasPrefix("old line\r\nsecond"))
        XCTAssertEqual(pane.title, "Mine")
        pane.start()
        let state = pane.recoveryState()
        XCTAssertEqual(state.cwd, dir)
        XCTAssertEqual(state.profile.options["cwd"]?.stringValue, dir)
        XCTAssertEqual(state.type, "app:local-tab")
        pane.close()
    }

    func testOSC7DirectoryParsing() throws {
        let (pane, engine) = try makePane(command: "/bin/sh", args: [])
        pane.engine(engine, directoryChanged: "file://host/Users/me/My%20Dir")
        XCTAssertEqual(pane.workingDirectory, "/Users/me/My Dir")
        pane.engine(engine, titleChanged: "vim")
        XCTAssertEqual(pane.title, "vim")
    }
}

final class ProcessingTests: XCTestCase {
    func testProgressRegex() {
        let d = ProgressDetector()
        XCTAssertEqual(d.detect(in: "  45% done"), 45)
        XCTAssertEqual(d.detect(in: "[12.5%]"), 12.5)
        XCTAssertNil(d.detect(in: "0%"))
        XCTAssertNil(d.detect(in: "150%"))
        XCTAssertNil(d.detect(in: "no progress"))
    }

    func testLoginScripts() {
        let scripts = [
            LoginScript(["expect": "login:", "send": "admin"])!,
            LoginScript(["expect": "Password:", "send": "secret\\r"])!,
            LoginScript(["expect": "never", "send": "x", "optional": true])!,
            LoginScript(["expect": "\\$ $", "send": "uptime", "isRegex": true])!,
        ]
        let r = LoginScriptRunner(scripts: scripts)
        XCTAssertEqual(r.process("Welcome"), [])
        XCTAssertEqual(r.process("host login:"), ["admin\n"])
        XCTAssertEqual(r.process("Password:"), ["secret\r\n"])
        XCTAssertEqual(r.process("user@host:~$ "), ["uptime\n"], "optional script skipped")
        XCTAssertTrue(r.isDone)
        XCTAssertEqual(LoginScriptRunner(scripts: [LoginScript(["send": "hi"])!]).unconditionalScripts(), ["hi\n"])
    }

    func testPastePreparation() {
        XCTAssertEqual(PastePreparation.prepare("a\r\nb\n", trimWhitespace: true, replaceNewlinesWithSpaces: false), "a\rb")
        XCTAssertEqual(PastePreparation.prepare("a\nb", trimWhitespace: false, replaceNewlinesWithSpaces: true), "a b")
        XCTAssertTrue(PastePreparation.needsMultilineWarning("a\rb", enabled: true, alternateScreen: false))
        XCTAssertFalse(PastePreparation.needsMultilineWarning("a\rb", enabled: true, alternateScreen: true))
        XCTAssertEqual(PastePreparation.bracketed("x", enabled: true), "\u{1b}[200~x\u{1b}[201~")
    }

    func testLocalOptionsEnvironment() throws {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        XCTAssertEqual(TerminalSettings(config: store).fontName, "Menlo")
        XCTAssertEqual(TerminalSettings(config: store).cursor, .block)
        let env = SessionEnvironment.make(base: ["PATH": "/bin", "TERM_SESSION_ID": "x"], overrides: ["A": "1"])
        XCTAssertNil(env["TERM_SESSION_ID"])
        XCTAssertEqual(env["TERM_PROGRAM"], "TabbyMac")
        XCTAssertEqual(env["A"], "1")
        XCTAssertEqual(env["LANG"], "en_US.UTF-8")
    }
}
