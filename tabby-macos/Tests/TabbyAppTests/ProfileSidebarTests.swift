#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: Tabby's profile sidebar (`showProfileTree`, `profileTree.component`).
@MainActor
final class ProfileSidebarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    override func tearDown() {
        AppServices.shared.config.set("showProfileTree", nil)
        super.tearDown()
    }

    func registry(_ user: ConfigValue) throws -> ProfileRegistry {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: user)
        return ProfileRegistry(config: store, providers: [SSHProfileProvider(sshConfig: { "" })], recents: RecentProfilesStore(url: nil))
    }

    func testSidebarShowsWhenTheSettingIsOn() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.root.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        c.root.layoutSubtreeIfNeeded()
        XCTAssertNil(c.root.sidebar, "off by default")
        AppServices.shared.config.set("showProfileTree", true)
        XCTAssertTrue(TestApp.pump(until: { c.root.sidebar != nil }))
        c.root.needsLayout = true
        c.root.layoutSubtreeIfNeeded()
        XCTAssertEqual(c.root.sidebar?.frame.width, c.root.sidebarWidth)
        XCTAssertEqual(c.root.tabBar?.frame.minX, c.root.sidebarWidth, "the tab bar starts after the sidebar")
        AppServices.shared.config.set("showProfileTree", false)
        XCTAssertTrue(TestApp.pump(until: { c.root.sidebar == nil }))
    }

    func testSidebarWidthIsClamped() {
        XCTAssertEqual(ProfileSidebar.width(stored: nil), 250)
        XCTAssertEqual(ProfileSidebar.width(stored: 50), 150)
        XCTAssertEqual(ProfileSidebar.width(stored: 900), 500)
        XCTAssertEqual(ProfileSidebar.width(stored: 320), 320)
    }

    func testSidebarFilterAndHiddenProfiles() throws {
        let r = try registry(["profiles": [["id": "a", "name": "alpha", "type": "ssh", "options": ["host": "h"]],
                                           ["id": "b", "name": "beta", "type": "ssh", "options": ["host": "h"]]],
                              "profileBlacklist": ["b"]])
        func ids(_ nodes: [ProfileTreeNode]) -> [String] { nodes.flatMap { $0.profiles.map(\.id) + ids($0.children) } }
        XCTAssertEqual(ids(ProfileTreeView.visibleTree(filter: "", registry: r)), ["a"], "hidden profiles are left out")
        XCTAssertEqual(ids(ProfileTreeView.visibleTree(filter: "zzz", registry: r)), [])
        XCTAssertEqual(ids(ProfileTreeView.visibleTree(filter: "alp", registry: r)), ["a"])
    }

    func testOpeningFromTheSidebarOpensATab() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let before = c.model.tabs.count
        c.openFromSidebar(TestApp.profile("sidebar", "sleep 5"))
        XCTAssertEqual(c.model.tabs.count, before + 1)
    }
}
#endif
