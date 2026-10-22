#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbyCore
@testable import TabbyApp

/// Renders the main screens to PNG files for comparing with the design canvases without a
/// display (works while the Mac is locked). Skipped unless `TABBYMAC_SNAPSHOT_DIR` is set:
///
///     TABBYMAC_SNAPSHOT_DIR=/tmp/shots swift test --filter DesignSnapshotTests
/// The editor sheet on a given page, for snapshots.
private struct ProfileEditorSnapshot: View {
    let profile: Profile
    let page: ProfileEditorSheet.Page

    var body: some View {
        ProfileEditorSheet(item: EditableProfile(profile, isNew: false), initialPage: page) { _ in }
    }
}

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

    func testProfileEditor() throws {
        var ssh = Profile(type: "ssh", name: "prod-web-01",
                          options: ["host": "prod-web-01.acme.internal", "port": 22, "user": "deploy",
                                    "privateKeys": ["~/.ssh/id_ed25519"], "forwardedPorts": [["type": "local", "host": "127.0.0.1", "port": 5432, "targetAddress": "db.internal", "targetPort": 5432]]])
        ssh.color = "#ff615a"
        for page in ProfileEditorSheet.Page.allCases {
            let view = NSHostingView(rootView: ProfileEditorSnapshot(profile: ssh, page: page).chromeEnvironment())
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 660)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            TestApp.pump(0.3)
            try save(view, "editor-\(page.rawValue.replacingOccurrences(of: " ", with: "-"))")
        }
    }

    private func render<V: View>(_ view: V, _ size: NSSize, _ name: String) throws {
        let host = NSHostingView(rootView: view.chromeEnvironment())
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        TestApp.pump(0.3)
        try save(host, name)
    }

    func testOverlaysAndCards() throws {
        let items = [
            SelectorItem(id: "1", title: "prod-web-01", group: "Recent", subtitle: "deploy@prod-web-01.acme.internal", icon: "server.rack", color: "#ff615a") {},
            SelectorItem(id: "2", title: "prod-web-02", group: "Acme / Production", subtitle: "deploy@prod-web-02.acme.internal", icon: "server.rack") {},
            SelectorItem(id: "3", title: "prod-db-primary", group: "Acme / Production", subtitle: "postgres@prod-db-primary", icon: "server.rack") {},
            SelectorItem(id: "4", title: "Manage profiles", group: "Actions", subtitle: "Settings › Profiles & connections", icon: "gearshape") {},
        ]
        try render(SelectorView(placeholder: "Select a profile or type user@host", items: items, dynamicItems: nil) { _ in },
                   SelectorPanel.size, "selector")
        try render(PasteWarningCard(text: "cd /srv/api\ngit fetch origin && git reset --hard origin/main\nsudo systemctl restart api\njournalctl -u api -n 50 --no-pager") { _, _ in },
                   NSSize(width: 460, height: 330), "card-paste")
        try render(HostKeyPromptCard(host: "prod-web-01.acme.internal:22", keyType: "ssh-ed25519",
                                     fingerprint: "SHA256:qX3m9vT2pKcY8hN1rB7eW4uF6sJ0aL5dZ2gH9xC3oVk") { _ in },
                   NSSize(width: 480, height: 360), "card-hostkey")
        try render(TextPromptCard(symbol: "lock", title: "Password for deploy@prod-web-01", message: "prod-web-01", secure: true,
                                  remember: "Remember in Keychain", confirm: "Log in", finish: { _, _ in }, value: "hunter2"),
                   NSSize(width: 400, height: 220), "card-password")
        let center = ToastCenter()
        center.show(ToastCenter.Toast(symbol: "checkmark.circle.fill", tint: .success, title: "Process completed",
                                      detail: "terraform apply exited with code 0 in tab 4 · 3m 12s", actionTitle: "Show", action: {}))
        try render(ToastOverlay(center: center), NSSize(width: 520, height: 110), "toast")
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
