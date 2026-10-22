#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Renders the main screens to PNG files for comparing with the design canvases without a
/// display (works while the Mac is locked). Skipped unless `TABBYMAC_SNAPSHOT_DIR` is set:
///
///     TABBYMAC_SNAPSHOT_DIR=/tmp/shots swift test --filter DesignSnapshotTests
@MainActor
final class DesignSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["TABBYMAC_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TABBYMAC_SNAPSHOT_DIR to render the screens")
        }
        directory = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TestApp.boot()
    }

    private func save(_ view: NSView, _ name: String) throws {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func window(_ size: NSSize = NSSize(width: 1280, height: 800)) -> MainWindowController {
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        controller.window?.setContentSize(size)
        return controller
    }

    private func set(_ key: String, _ value: ConfigValue?) {
        AppServices.shared.config.set(key, value)
        addTeardownBlock { @MainActor in AppServices.shared.config.set(key, nil) }
    }

    func testMainWindow() throws {
        for mode in ["dark", "light"] {
            set("appearance.colorSchemeMode", .string(mode))
            let c = window()
            defer { TestApp.dispose(c) }
            let pinned = c.model.openTab(profile: TestApp.profile("htop", "printf 'htop\\n'; sleep 30"))
            pinned?.isPinned = true
            c.model.openTab(profile: TestApp.profile("Projects", "printf 'alex@mbp ~/Projects %% swift build\\nBuilding for production...\\n'; sleep 30"))
            let prod = c.model.openTab(profile: TestApp.profile("prod-web-01", "sleep 30"))
            prod?.color = "#ff615a"
            c.model.openTab(profile: TestApp.profile("swift test", "printf 'Testing 42%%\\n'; sleep 30"))
            c.model.openTab(profile: TestApp.profile("logs", "sleep 30"))
            if let second = c.model.tabs.dropFirst().first { c.model.select(second.id) }
            TestApp.pump(1.5)
            try save(try XCTUnwrap(c.window?.contentView), "main-\(mode)")
        }
    }

    func testTabOverflow() throws {
        let c = window(NSSize(width: 960, height: 400))
        defer { TestApp.dispose(c) }
        for i in 1...12 { c.model.openTab(profile: TestApp.profile("tab-\(i)", "sleep 30")) }
        TestApp.pump(1)
        try save(try XCTUnwrap(c.window?.contentView), "overflow-fixed")
        set("appearance.flexTabs", true)
        TestApp.pump(0.5)
        try save(try XCTUnwrap(c.window?.contentView), "overflow-flex")
    }

    func testVerticalTabs() throws {
        set("appearance.tabsLocation", "left")
        let c = window()
        defer { TestApp.dispose(c) }
        for name in ["~/Projects", "prod-web-01", "logs — api"] { c.model.openTab(profile: TestApp.profile(name, "sleep 30")) }
        TestApp.pump(1)
        try save(try XCTUnwrap(c.window?.contentView), "main-left")
    }

    func testStartPage() throws {
        AppServices.shared.profiles.recents.push(TestApp.profile("staging-db", "sleep 30"))
        AppServices.shared.profiles.recents.push(TestApp.profile("prod-web-01", "sleep 30"))
        let c = window()
        defer { TestApp.dispose(c) }
        TestApp.pump(0.5)
        try save(try XCTUnwrap(c.window?.contentView), "start")
    }

    func testContentTabs() throws {
        let c = window()
        defer { TestApp.dispose(c) }
        c.model.openTab(profile: TestApp.profile("~/Projects", "sleep 30"))
        c.model.openWelcome()
        TestApp.pump(0.8)
        try save(try XCTUnwrap(c.window?.contentView), "welcome")
        for section in SettingsSection.allCases {
            c.model.openSettings(section: section)
            TestApp.pump(0.6)
            try save(try XCTUnwrap(c.window?.contentView), "settings-\(section)")
        }
    }
}
#endif
