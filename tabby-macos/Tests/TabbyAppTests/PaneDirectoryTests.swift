#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 6: dropping files on a pane (Tabby's `PathDropDecorator`), "New terminal" / "New
/// with profile" (`tabby-local/src/tabContextMenu.ts`) and "Save as profile"
/// (`SaveAsProfileContextMenu`).
@MainActor
final class PaneDirectoryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func titles(_ menu: NSMenu) -> [String] { menu.items.map(\.title) }
    func resolved(_ path: String?) -> String? { path.map { ($0 as NSString).resolvingSymlinksInPath } }

    /// A window with one local tab running `script`, once its shell is in `directory`.
    func window(_ script: String, in directory: String? = nil, name: String = "here") throws -> (MainWindowController, TerminalPane) {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile(name, script)))
        let pane = try XCTUnwrap(tab.focusedPane)
        TestApp.pump(until: { pane.isRunning })
        if let directory { XCTAssertTrue(TestApp.pump(until: { pane.currentDirectory() == directory })) }
        return (c, pane)
    }

    func testDroppedFilesAreTypedQuoted() throws {
        let (c, pane) = try window("cat")
        defer { TestApp.dispose(c) }
        c.dropFiles([URL(fileURLWithPath: "/tmp/a b"), URL(fileURLWithPath: "/x/it's")], on: pane)
        XCTAssertTrue(TestApp.pump(until: { pane.engine?.snapshotText(maxLines: 10).contains("'/tmp/a b' '/x/it'\\''s'") == true }),
                      pane.engine?.snapshotText(maxLines: 5) ?? "")
        XCTAssertEqual(c.model.activePane?.id, pane.id)
    }

    func testNewTerminalOpensTheSameLocalProfileWhereThePaneIs() throws {
        let (c, pane) = try window("cd /usr; sleep 30", in: "/usr")
        defer { TestApp.dispose(c) }
        let menu = c.terminalContextMenu(for: pane)
        XCTAssertTrue(titles(menu).contains("New terminal"), "\(titles(menu))")
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "New with profile" }?.submenu)
        XCTAssertFalse(submenu.items.isEmpty)
        XCTAssertTrue(submenu.items.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(c.runCommand("new-terminal"))
        let opened = try XCTUnwrap(c.model.activePane)
        XCTAssertFalse(opened === pane)
        XCTAssertEqual(opened.profile.id, pane.profile.id)
        XCTAssertTrue(TestApp.pump(until: { opened.currentDirectory() == "/usr" }), opened.currentDirectory() ?? "nil")
    }

    func testNewWithProfileOpensItWhereThePaneIs() throws {
        let saved = AppServices.shared.profiles.save(TestApp.profile("Phase 6 shell", "sleep 30"))
        defer { AppServices.shared.profiles.delete(profileId: saved.id) }
        let (c, pane) = try window("cd /usr; sleep 30", in: "/usr")
        defer { TestApp.dispose(c) }
        let submenu = try XCTUnwrap(c.terminalContextMenu(for: pane).items.first { $0.title == "New with profile" }?.submenu)
        XCTAssertTrue(titles(submenu).contains("Phase 6 shell"), "\(titles(submenu))")
        XCTAssertTrue(c.runCommand("new-with-profile:\(saved.id)"))
        let opened = try XCTUnwrap(c.model.activePane)
        XCTAssertEqual(opened.profile.id, saved.id)
        XCTAssertTrue(TestApp.pump(until: { opened.currentDirectory() == "/usr" }), opened.currentDirectory() ?? "nil")
    }

    func testALocalTabNeverTakesTheFolderOfARemotePane() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let remote = Profile(id: "telnet:nowhere", type: "telnet", name: "nowhere",
                             options: ["host": "127.0.0.1", "port": 1])
        let tab = try XCTUnwrap(c.model.openTab(profile: remote))
        let pane = try XCTUnwrap(tab.focusedPane)
        TestApp.pump(0.3)
        pane.engine(try XCTUnwrap(pane.engine), directoryChanged: "/usr")
        let local = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("plain", "sleep 30"))?.focusedPane)
        TestApp.pump(until: { local.currentDirectory() != nil })
        XCTAssertEqual(resolved(local.currentDirectory()), resolved(NSHomeDirectory()), "Tabby inherits only from local tabs")
    }

    func testSaveAsProfileKeepsTheProfileAndTheFolder() throws {
        var profile = TestApp.profile("styled", "cd /usr; sleep 30")
        profile.icon = "server"
        profile.color = "#ff0000"
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: profile)?.focusedPane)
        XCTAssertTrue(TestApp.pump(until: { pane.currentDirectory() == "/usr" }))
        XCTAssertTrue(titles(c.terminalContextMenu(for: pane)).contains("Save as profile"))
        let tab = try XCTUnwrap(c.model.activeTab)
        XCTAssertTrue(titles(TabMenu.build(for: tab, actions: c.tabBarActions!)).contains("Save as profile"))
        let saved = try XCTUnwrap(c.saveAsProfile(pane, name: "Saved here"))
        defer { AppServices.shared.profiles.delete(profileId: saved.id) }
        let stored = try XCTUnwrap(AppServices.shared.profiles.allProfiles().first { $0.id == saved.id })
        XCTAssertEqual(stored.name, "Saved here")
        XCTAssertEqual(stored.type, "local")
        XCTAssertEqual(stored.icon, "server")
        XCTAssertEqual(stored.color, "#ff0000")
        XCTAssertEqual(LocalOptions(stored.options).cwd, "/usr")
        XCTAssertEqual(LocalOptions(stored.options).args, ["-c", "cd /usr; sleep 30"])
        XCTAssertTrue(stored.id.hasPrefix("local:custom:"), stored.id)
        XCTAssertEqual(c.toasts.toasts.last?.title, "Saved")
    }
}
#endif
