#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 6: what a clicked link does in the app (Tabby's linkifier handlers).
@MainActor
final class LinkOpeningTests: XCTestCase {
    var opened: [URL] = []
    var revealed: [URL] = []

    override func setUp() {
        super.setUp()
        TestApp.boot()
        opened = []
        MainWindowController.openURL = { [unowned self] in self.opened.append($0) }
        MainWindowController.revealInFinder = { [unowned self] in self.revealed.append($0) }
    }

    override func tearDown() {
        MainWindowController.openURL = MainWindowController.defaultOpenURL
        MainWindowController.revealInFinder = MainWindowController.defaultRevealInFinder
        AppServices.shared.config.set("clickableLinks.modifier", .null)
        super.tearDown()
    }

    func testLinksOpenWhatTheyPointAt() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("here", "cd /usr; sleep 30"))?.focusedPane)
        XCTAssertTrue(TestApp.pump(until: { pane.currentDirectory() == "/usr" }))
        pane.onOpenLink?(pane, "https://example.com/a")
        pane.onOpenLink?(pane, "10.0.0.1:8080")
        pane.onOpenLink?(pane, "share/man")
        pane.onOpenLink?(pane, "javascript:alert(1)")
        pane.onOpenLink?(pane, "missing/file.txt")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/a", "http://10.0.0.1:8080", "file:///usr/share/man/"])
    }

    func testAnSSHLinkOpensAQuickConnectTab() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("here", "sleep 30"))?.focusedPane)
        pane.onOpenLink?(pane, "ssh://me@127.0.0.1:1")
        XCTAssertEqual(c.model.tabs.count, 2)
        let ssh = try XCTUnwrap(c.model.activePane)
        XCTAssertEqual(ssh.profile.type, "ssh")
        XCTAssertEqual(SSHOptions(ssh.profile.options).user, "me")
        XCTAssertEqual(SSHOptions(ssh.profile.options).port, 1)
        XCTAssertTrue(opened.isEmpty)
        // Port 1 refuses at once; let the session-ended notice post during this test, not into
        // the next test's recorder (Notifier posts asynchronously).
        TestApp.pump(until: { !ssh.isRunning && ssh.hasStarted })
        TestApp.pump(0.6)
    }

    func testTheModifierSettingReachesTheTerminals() throws {
        XCTAssertEqual(AppServices.shared.terminalSettings.linkModifier, .none, "Tabby's default")
        AppServices.shared.config.set("clickableLinks.modifier", .string("shiftKey"))
        XCTAssertEqual(AppServices.shared.terminalSettings.linkModifier, .shift)
    }

    /// Review: with a plain click now opening links, a click on `./deploy.command` or an app
    /// would run it. Programs and apps are shown in Finder instead.
    func testAClickNeverRunsAProgram() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabbymac-links-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Thing.app"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("deploy.command")
        try Data("#!/bin/sh\necho deployed\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let notes = folder.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: notes)
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("here", "sleep 30"))?.focusedPane)
        c.openLink(script.path, from: pane)
        c.openLink(folder.appendingPathComponent("Thing.app").path, from: pane)
        c.openLink(notes.path, from: pane)
        XCTAssertEqual(revealed.map(\.lastPathComponent), ["deploy.command", "Thing.app"])
        XCTAssertEqual(opened.map(\.lastPathComponent), ["notes.txt"])
    }
}
#endif
