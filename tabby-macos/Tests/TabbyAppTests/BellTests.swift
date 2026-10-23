#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 5: SwiftTerm only reports the bell in audible mode; TabbyMac needs it in every mode
/// (activity, Dock bounce).
@MainActor
final class AppBellTests: XCTestCase {
    final class Spy: TerminalEngineDelegate {
        var bells = 0
        func engineBell(_ engine: TerminalEngine) { bells += 1 }
        func engine(_ engine: TerminalEngine, send data: Data) {}
        func engine(_ engine: TerminalEngine, resized cols: Int, rows: Int) {}
        func engine(_ engine: TerminalEngine, titleChanged title: String) {}
        func engine(_ engine: TerminalEngine, directoryChanged directory: String?) {}
        func engineDidFocus(_ engine: TerminalEngine) {}
        func engine(_ engine: TerminalEngine, paste text: String) {}
        func engineSelectionChanged(_ engine: TerminalEngine) {}
    }

    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    func testTheEngineReportsTheBellWhenSilentOrVisual() throws {
        // Not "audible": it would beep on the test Mac (that path always reported the bell).
        for mode in ["off", "visual"] {
            let config = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: ["terminal": ["bell": .string(mode)]])
            let settings = TerminalSettings(config: config)
            let engine = SwiftTermEngine(frame: CGRect(x: 0, y: 0, width: 400, height: 200), settings: settings)
            engine.apply(settings: settings, scheme: .tabbyDefault, fontSize: settings.fontSize)
            let spy = Spy()
            engine.engineDelegate = spy
            engine.feed(Data([0x07]))
            XCTAssertEqual(spy.bells, 1, mode)
        }
    }

    func testTheDockIconBouncesWhenTheSettingIsOnAndTheAppIsInTheBackground() throws {
        var bounces = 0
        MainWindowController.requestAttention = { bounces += 1 }
        defer {
            MainWindowController.requestAttention = { NSApp.requestUserAttention(.informationalRequest) }
            AppServices.shared.config.set("terminal.bellFlashFrame", .null)
        }
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("b", "sleep 30"))?.focusedPane)
        c.paneRang(pane, appIsActive: false)
        XCTAssertEqual(bounces, 0, "off by default, as in Tabby")
        AppServices.shared.config.set("terminal.bellFlashFrame", .bool(true))
        c.paneRang(pane, appIsActive: true)
        XCTAssertEqual(bounces, 0, "not while TabbyMac is in front")
        c.paneRang(pane, appIsActive: false)
        XCTAssertEqual(bounces, 1)
        TestApp.pump(until: { pane.engine != nil })
        pane.engineBell(try XCTUnwrap(pane.engine))
        XCTAssertEqual(bounces, NSApp.isActive ? 1 : 2, "the pane's bell reaches the window")
    }
}
#endif
