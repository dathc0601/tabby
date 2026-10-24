#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 6: Tabby's "Export to file" (`tabby-electron/src/terminalContextMenu.ts`) and the
/// Settings rows of 6.1.
@MainActor
final class ExportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    override func tearDown() {
        MainWindowController.chooseExportURL = MainWindowController.defaultChooseExportURL
        super.tearDown()
    }

    func window(_ script: String) throws -> (MainWindowController, TerminalPane) {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        let tab = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("export", script)))
        let pane = try XCTUnwrap(tab.focusedPane)
        TestApp.pump(until: { pane.isRunning })
        return (c, pane)
    }

    func testExportWritesTheWholeBufferAndSaysWhere() throws {
        let (c, pane) = try window("printf 'first\\nexported text\\n'; sleep 30")
        defer { TestApp.dispose(c) }
        XCTAssertTrue(TestApp.pump(until: { pane.engine?.snapshotText(maxLines: 10).contains("exported text") == true }))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tabbymac-export-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        var suggested: String?
        MainWindowController.chooseExportURL = { _, name, _, done in suggested = name; done(file) }
        XCTAssertTrue(c.runCommand("export-buffer"))
        XCTAssertEqual(suggested, "terminal.txt")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("first\nexported text"), text)
        XCTAssertEqual(c.toasts.toasts.last?.title, "Saved to \(file.path)")
    }

    func testAFailedWriteSaysSo() throws {
        let (c, _) = try window("sleep 30")
        defer { TestApp.dispose(c) }
        let file = URL(fileURLWithPath: "/nonexistent-folder-\(UUID().uuidString)/terminal.txt")
        MainWindowController.chooseExportURL = { _, _, _, done in done(file) }
        XCTAssertTrue(c.runCommand("export-buffer"))
        XCTAssertEqual(c.toasts.toasts.last?.title, "Could not save the file")
        XCTAssertEqual(c.toasts.toasts.last?.tint, .warning)
    }

    func testBothMenusOfferExport() throws {
        let (c, pane) = try window("sleep 30")
        defer { TestApp.dispose(c) }
        XCTAssertNotNil(c.terminalContextMenu(for: pane).items.first { $0.title == "Export to file" })
        let tab = try XCTUnwrap(c.model.activeTab)
        XCTAssertNotNil(TabMenu.build(for: tab, actions: c.tabBarActions!).items.first { $0.title == "Export to file" })
    }

    func testTheNewTerminalSettingsAreRead() throws {
        let config = AppServices.shared.config
        defer {
            config.set("terminal.copyAsHTML", .null)
            config.set("terminal.wordSeparator", .null)
        }
        XCTAssertTrue(TerminalSettings(config: config).copyAsHTML, "Tabby's default")
        XCTAssertEqual(TerminalSettings(config: config).wordSeparator, " ()[]{}'\"")
        config.set("terminal.copyAsHTML", .bool(false))
        config.set("terminal.wordSeparator", .string(" /"))
        XCTAssertFalse(TerminalSettings(config: config).copyAsHTML)
        XCTAssertEqual(TerminalSettings(config: config).wordSeparator, " /")
    }
}
#endif
