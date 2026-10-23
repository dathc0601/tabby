#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Settings and Welcome open as tabs (the phase 2 design, as in Tabby) instead of windows.
@MainActor
final class ContentTabTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    private func settingsTabs(_ c: MainWindowController) -> [TabModel] {
        c.model.tabs.filter { $0.content == .settings }
    }

    func testSettingsTabIsASingletonPerWindow() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab(profile: TestApp.profile("term", "sleep 30"))
        c.model.openSettings()
        let first = settingsTabs(c).first
        XCTAssertNotNil(first)
        XCTAssertTrue(c.model.activeTab === first)
        XCTAssertEqual(c.model.activeTab?.title, "Settings")
        c.model.select(index: 0)
        c.model.openSettings(section: .hotkeys)
        XCTAssertEqual(settingsTabs(c).count, 1, "the open Settings tab is focused, not duplicated")
        XCTAssertTrue(c.model.activeTab === first)
        XCTAssertEqual(first?.settingsNavigation?.section, .hotkeys)
    }

    func testSettingsCommandOpensTheTab() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        XCTAssertTrue(c.runCommand("settings"))
        XCTAssertEqual(c.model.activeTab?.content, .settings)
    }

    func testContentTabsAreNotRecoveredAndCloseWithoutAsking() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab(profile: TestApp.profile("term", "sleep 30"))
        c.model.openSettings()
        c.model.openWelcome()
        XCTAssertEqual(c.model.tabs.count, 3)
        XCTAssertEqual(c.model.recoveryTokens(includeBuffers: false).count, 1, "only the terminal tab is saved")
        let welcome = c.model.tabs.first { $0.content == .welcome }!
        c.requestCloseTab(welcome)
        XCTAssertNil(c.window?.attachedSheet)
        XCTAssertFalse(c.model.tabs.contains { $0 === welcome })
    }

    func testSplittingASettingsTabOpensATerminalTab() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openSettings()
        let settings = c.model.activeTab
        c.model.split(.right, profile: TestApp.profile("split", "sleep 30"))
        XCTAssertEqual(settings?.panes.count, 0, "nothing is inserted into the Settings tab")
        XCTAssertEqual(c.model.tabs.count, 2)
        XCTAssertNil(c.model.activeTab?.content)
    }

    func testCombineKeepsContentTabsOut() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab(profile: TestApp.profile("a", "sleep 30"))
        c.model.openTab(profile: TestApp.profile("b", "sleep 30"))
        c.model.openSettings()
        c.model.combineTabs()
        XCTAssertEqual(settingsTabs(c).count, 1)
        XCTAssertEqual(settingsTabs(c).first?.panes.count, 0, "combine does nothing while Settings is active")
        c.model.select(index: 0)
        c.model.combineTabs()
        XCTAssertEqual(settingsTabs(c).count, 1, "Settings survives combining the terminal tabs")
        XCTAssertEqual(c.model.tabs.filter { $0.content == nil }.count, 1)
    }

    func testContentTabHostsItsView() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openSettings()
        let tab = try XCTUnwrap(c.model.activeTab)
        // The window builds tab views from an observation callback; CI runners can be slow.
        TestApp.pump(until: { c.contentTabView(for: tab) != nil })
        let content = try XCTUnwrap(c.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(c.contentTabView(for: tab))
        XCTAssertFalse(host.isHidden)
        XCTAssertGreaterThan(host.frame.height, 300)
    }

    /// The start page lists up to three recent profiles; ⌘1–⌘3 (`tab-1`…`tab-3`) open them
    /// while the window has no tabs.
    func testCommandDigitsOpenRecentProfilesOnTheStartPage() {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let recent = TestApp.profile("recent-one", "sleep 30")
        AppServices.shared.profiles.recents.push(recent)
        XCTAssertEqual(StartPageView.recentProfiles().first?.name, "recent-one")
        XCTAssertTrue(c.runCommand("tab-1"))
        XCTAssertEqual(c.model.tabs.count, 1)
        XCTAssertEqual(c.model.activeTab?.focusedPane?.profile.name, "recent-one")
        XCTAssertTrue(c.runCommand("tab-1"), "with tabs open, ⌘1 selects the first tab again")
        XCTAssertEqual(c.model.tabs.count, 1)
    }

    /// Presses `key` in `window` as the keyboard would.
    private func press(_ keyCode: UInt16, _ characters: String, in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber, context: nil, characters: characters,
                                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
            window.sendEvent(event)
            TestApp.pump(0.05)
        }
    }

    /// The start page takes ↓ and ↩ and starts at the top each time it shows (Tabby builds a new
    /// start page). Found in the M6 walk: after the last tab closed, ↓ did nothing.
    func testTheStartPageTakesTheArrowKeysAfterTheLastTabCloses() throws {
        let recents = AppServices.shared.profiles.recents
        recents.clear()
        defer { recents.clear() }
        recents.push(TestApp.profile("recent-two", "sleep 30"))
        recents.push(TestApp.profile("recent-one", "sleep 30"))
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let window = try XCTUnwrap(c.window)
        let down = (UInt16(125), String(UnicodeScalar(NSDownArrowFunctionKey)!))
        let enter = (UInt16(36), "\r")

        func openFirstRecentWithTheKeyboard() {
            TestApp.pump(0.3)
            press(down.0, down.1, in: window)
            press(down.0, down.1, in: window)
            press(enter.0, enter.1, in: window)
            TestApp.pump(until: { !c.model.tabs.isEmpty }, timeout: 2)
        }
        openFirstRecentWithTheKeyboard()
        XCTAssertEqual(c.model.activeTab?.focusedPane?.profile.name, "recent-one", "a fresh start page takes the keys")

        for tab in c.model.tabs { tab.orderedPanes.forEach { $0.close() }; c.model.closeTab(tab.id) }
        TestApp.pump(until: { c.model.tabs.isEmpty })
        openFirstRecentWithTheKeyboard()
        XCTAssertEqual(c.model.activeTab?.focusedPane?.profile.name, "recent-one", "and again after the last tab closed")
    }

    /// The spec: on a launch that restores no tabs, until "Close and never show again". A
    /// restored session is not a first run and keeps its selected tab.
    func testWelcomeShowsOnAFreshLaunchUntilDismissed() {
        let config = AppServices.shared.config
        defer { config.set("enableWelcomeTab", nil) }
        XCTAssertTrue(WelcomePolicy.shouldShow(config: config, restoredTabs: false), "enableWelcomeTab defaults to true")
        XCTAssertFalse(WelcomePolicy.shouldShow(config: config, restoredTabs: true))
        WelcomePolicy.dismissForever(config: config)
        XCTAssertFalse(WelcomePolicy.shouldShow(config: config, restoredTabs: false))
    }
}
#endif
