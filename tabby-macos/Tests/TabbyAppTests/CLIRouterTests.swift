#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyCLIKit
@testable import TabbyApp

/// Phase 5: what `tabby …`, tabbymac:// and ssh:// / telnet:// links do in the app (Tabby's
/// CLIHandlers: `tabby-core/src/cli.ts`, `tabby-local/src/cli.ts`, `tabby-terminal/src/cli.ts`).
@MainActor
final class CLIRouterTests: XCTestCase {
    var router: CLIRouter!
    var controller: MainWindowController!
    var asked: [String] = []
    var messages: [String] = []
    var answer = true
    var directory: URL!

    override func setUp() {
        super.setUp()
        TestApp.boot()
        controller = WindowManager.shared.newWindow(openDefaultTab: false)
        router = CLIRouter()
        router.target = { [unowned self] in self.controller }
        router.confirm = { [unowned self] title, message, _, done in
            self.asked.append(title)
            self.messages.append(message)
            done(self.answer)
        }
        router.becomeReady()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        TestApp.dispose(controller)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    var tabs: [TabModel] { controller.model.tabs }
    var lastProfile: Profile? { tabs.last?.focusedPane?.profile }
    var lastToast: String? { controller.toasts.toasts.last.map { [$0.title, $0.detail].filter { !$0.isEmpty }.joined(separator: " ") } }

    func testOpenStartsAShellInTheDirectory() throws {
        router.handle(.open(directory: "sub"), cwd: directory.path)
        let pane = try XCTUnwrap(tabs.last?.focusedPane)
        XCTAssertEqual(pane.profile.type, "local")
        let expected = directory.appendingPathComponent("sub").resolvingSymlinksInPath().path
        TestApp.pump(until: { pane.currentDirectory().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == expected })
        XCTAssertEqual(pane.currentDirectory().map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, expected)
    }

    func testOpenWithoutADirectoryUsesTheCallersOne() throws {
        router.handle(.open(directory: nil), cwd: directory.path)
        XCTAssertEqual(tabs.count, 1)
    }

    func testOpenAMissingDirectorySaysSo() {
        router.handle(.open(directory: "/nonexistent/place"), cwd: "/")
        XCTAssertTrue(tabs.isEmpty)
        XCTAssertEqual(lastToast, "No such directory /nonexistent/place")
    }

    func testRunAsksThenRunsTheCommandAndKeepsTheTabOpen() throws {
        router.handle(.run(command: ["ls", "-la"], cwd: directory.path), cwd: "/")
        XCTAssertEqual(asked, ["Run \"ls -la\"?"])
        let options = LocalOptions(try XCTUnwrap(lastProfile).options)
        XCTAssertEqual(options.command, "ls")
        XCTAssertEqual(options.args, ["-la"])
        XCTAssertEqual(options.cwd, directory.path)
        XCTAssertTrue(options.pauseAfterExit)
        answer = false
        router.handle(.run(command: ["rm", "-rf", "x"], cwd: nil), cwd: "/")
        XCTAssertEqual(tabs.count, 1, "Cancel runs nothing")
    }

    func testProfileOpensASavedProfileByName() throws {
        let saved = AppServices.shared.profiles.save(TestApp.profile("Router console", "sleep 30"))
        defer { AppServices.shared.profiles.delete(profileId: saved.id) }
        router.handle(.profile(name: "Router console"), cwd: "/")
        XCTAssertEqual(lastProfile?.name, "Router console")
        router.handle(.profile(name: "Nope"), cwd: "/")
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(lastToast, "No profile named “Nope”", "★ Tabby only logs it")
    }

    func testRecentOpensARecentProfile() throws {
        let recents = AppServices.shared.profiles.recents
        recents.clear()
        defer { recents.clear() }
        recents.push(TestApp.profile("older", "sleep 30"))
        recents.push(TestApp.profile("latest", "sleep 30"))
        router.handle(.recent(index: 0), cwd: "/")
        XCTAssertEqual(lastProfile?.name, "latest")
        router.handle(.recent(index: 9), cwd: "/")
        XCTAssertEqual(lastToast, "No recent profile 9")
    }

    func testQuickConnectAndLinksOpenConnections() throws {
        router.handle(.quickConnect(providerId: "telnet", query: "127.0.0.1:1"), cwd: "/")
        XCTAssertEqual(lastProfile?.type, "telnet")
        XCTAssertEqual(TelnetOptions(try XCTUnwrap(lastProfile).options).port, 1)
        XCTAssertTrue(router.handle(url: URL(string: "ssh://deploy@127.0.0.1:1")!))
        let ssh = SSHOptions(try XCTUnwrap(lastProfile).options)
        XCTAssertEqual(lastProfile?.type, "ssh")
        XCTAssertEqual(ssh.user, "deploy")
        XCTAssertEqual(ssh.port, 1)
        XCTAssertTrue(router.handle(url: URL(string: "telnet://127.0.0.1:1")!))
        XCTAssertEqual(lastProfile?.type, "telnet")
        XCTAssertFalse(router.handle(url: URL(string: "https://example.com")!))
        router.handle(.quickConnect(providerId: "gopher", query: "x"), cwd: "/")
        XCTAssertEqual(lastToast, "Cannot open “x” with gopher")
    }

    func testPasteAsksThenTypesIntoTheFocusedPane() throws {
        controller.model.openTab(profile: TestApp.profile("cat", "cat"))
        let pane = try XCTUnwrap(tabs.last?.focusedPane)
        TestApp.pump(until: { pane.isRunning && pane.engine != nil })
        router.handle(.paste(text: "it's here", escape: true), cwd: "/")
        XCTAssertEqual(asked, ["Paste \"'it'\\''s here'\"?"], "shell-escaped, as `tabby paste -e`")
        TestApp.pump(until: { pane.engine?.snapshotText(maxLines: 20).contains("'it'\\''s here'") == true })
        XCTAssertTrue(pane.engine?.snapshotText(maxLines: 20).contains("'it'\\''s here'") == true)
    }

    /// Review: a link can carry kilobytes; the question must stay readable and show that
    /// there is more, so the end of a command can't hide off-screen.
    func testALongRunOrPasteShowsAShortPreviewAndSaysSo() throws {
        answer = false
        let long = String(repeating: "a", count: 5000) + "; rm -rf ~"
        router.handle(.paste(text: long, escape: false), cwd: "/")
        let title = try XCTUnwrap(asked.last)
        XCTAssertLessThan(title.count, 260, title)
        XCTAssertTrue(title.contains("…"))
        XCTAssertEqual(messages.last, "Only the start is shown: 5010 characters in all.")
        router.handle(.run(command: (1...40).map { "argument-number-\($0)" }, cwd: nil), cwd: "/")
        XCTAssertFalse(asked.last?.contains("argument-number-40") ?? true, "the end of a long command is cut, and the message says so")
        router.handle(.paste(text: (1...20).map { "echo \($0)" }.joined(separator: "\n"), escape: false), cwd: "/")
        XCTAssertLessThanOrEqual(asked.last?.components(separatedBy: "\n").count ?? 99, 6, "a few lines at most")
        router.handle(.paste(text: "short", escape: false), cwd: "/")
        XCTAssertEqual(messages.last, "", "nothing to add for a short text")
    }

    func testAPathOpensADirectoryOrRunsAScript() throws {
        router.handle(.path(directory.path), cwd: "/")
        XCTAssertEqual(tabs.count, 1)
        let script = directory.appendingPathComponent("deploy.sh")
        try "echo hi\n".write(to: script, atomically: true, encoding: .utf8)
        answer = false
        router.handle(.path("deploy.sh"), cwd: directory.path)
        XCTAssertEqual(asked, ["Run \"\(script.path)\"?"], "a link can name a script: it asks first")
        XCTAssertEqual(tabs.count, 1, "Cancel runs nothing")
        answer = true
        router.handle(.path("deploy.sh"), cwd: directory.path)
        let options = LocalOptions(try XCTUnwrap(lastProfile).options)
        XCTAssertEqual(options.args.last, script.path, "the default shell runs the script")
        XCTAssertTrue(options.pauseAfterExit)
        try "x".write(to: directory.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        router.handle(.path("notes.txt"), cwd: directory.path)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertEqual(asked.count, 2, "nothing to ask for a file it won't run")
        XCTAssertEqual(lastToast, "Cannot handle scripts of this type")
    }

    /// AppKit can hand over a link before the first window exists.
    func testRequestsWaitUntilTheAppIsReady() {
        let early = CLIRouter()
        early.target = { [unowned self] in self.controller }
        early.handle(.open(directory: nil), cwd: directory.path)
        XCTAssertTrue(early.hasPendingRequests)
        XCTAssertTrue(tabs.isEmpty)
        early.becomeReady()
        XCTAssertFalse(early.hasPendingRequests)
        XCTAssertEqual(tabs.count, 1)
    }

    func testLaunchArgumentsAreHandledAndBadOnesIgnored() {
        router.launchArguments(["-NSDocumentRevisionsDebugMode", "YES", "open", directory.path], cwd: "/")
        XCTAssertEqual(tabs.count, 1)
        router.launchArguments(["--bogus"], cwd: "/")
        router.launchArguments([], cwd: "/")
        XCTAssertEqual(tabs.count, 1)
    }
}
#endif

#if canImport(AppKit)
/// Settings › Application › Links and Command-line tool.
@MainActor
final class LinkHandlerTests: XCTestCase {
    func testTheHelperPathAndItsInstallCommand() {
        XCTAssertTrue(LinkHandlers.cliPath.hasSuffix("/tabby"), LinkHandlers.cliPath)
        XCTAssertEqual(LinkHandlers.installCommand, "sudo ln -sf \(ShellWords.quote(LinkHandlers.cliPath)) /usr/local/bin/tabby")
    }

    func testTheCurrentHandlerIsReadWithoutChangingIt() {
        XCTAssertEqual(LinkHandlers.schemes, ["ssh", "telnet"])
        _ = LinkHandlers.handlerName(for: "ssh")
        XCTAssertFalse(LinkHandlers.isDefault, "xctest is not the ssh:// handler")
        XCTAssertFalse(LinkHandlers.canChange, "only TabbyMac.app can make itself the handler")
    }
}
#endif
