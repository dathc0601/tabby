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
