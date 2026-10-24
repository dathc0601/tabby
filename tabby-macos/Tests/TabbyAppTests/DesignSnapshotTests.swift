#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbyCore
@testable import TabbyApp
import TabbyAccount
import TabbyTestSupport

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

    /// Phase 7: Tabby's profile sidebar beside the tabs.
    func testProfileSidebar() throws {
        let c = window()
        defer {
            AppServices.shared.config.set("showProfileTree", nil)
            TestApp.dispose(c)
        }
        c.model.openTab(profile: TestApp.profile("zsh", "printf 'ls\\n'; sleep 30"))
        AppServices.shared.config.set("showProfileTree", true)
        XCTAssertTrue(TestApp.pump(until: { c.root.sidebar != nil }))
        TestApp.pump(0.8)
        try save(try XCTUnwrap(c.window?.contentView), "profile-sidebar")
    }

    func testSplits() throws {
        let c = window()
        defer { TestApp.dispose(c) }
        c.model.openTab(profile: TestApp.profile("zsh", "printf 'swift test --filter TabBar\\n'; sleep 30"))
        c.model.split(.right, profile: TestApp.profile("logs", "printf 'tail -f access.log\\n'; sleep 30"))
        c.model.split(.bottom, profile: TestApp.profile("deploy", "printf 'uptime\\n'; sleep 30"))
        TestApp.pump(1.2)
        try save(try XCTUnwrap(c.window?.contentView), "split")
        c.model.toggleMaximize()
        TestApp.pump(0.6)
        try save(try XCTUnwrap(c.window?.contentView), "split-maximized")
        c.model.toggleMaximize()
        // Phase 6: a pane label, then the rearranging overlay.
        if let pane = c.model.activePane { c.renamePane(pane, to: "deploy logs") }
        TestApp.pump(0.4)
        try save(try XCTUnwrap(c.window?.contentView), "split-pane-label")
        c.model.activeTab?.isRearranging = true
        TestApp.pump(0.4)
        try save(try XCTUnwrap(c.window?.contentView), "split-rearranging")
        c.model.activeTab?.isRearranging = false
        c.model.broadcastAllTabs = true
        TestApp.pump(0.4)
        try save(try XCTUnwrap(c.window?.contentView), "broadcast-all-tabs")
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

    /// Phase 4: the screens of the Tabby Connections canvas (C1–C10), in both schemes.
    func testSerialAndTelnetScreens() throws {
        let serial = Profile(type: "serial", name: "Arduino", options: ["inputMode": "readline", "outputNewlines": "crlf"], color: "#8fcf7a")
        let telnet = Profile(type: "telnet", name: "Core switch", options: ["host": "switch.lan", "port": 23,
                                                                             "inputMode": "local-echo", "outputNewlines": "crlf"], color: "#56c8d8")
        let ports = [SerialPortInfo(path: "/dev/cu.usbserial-1420", description: "FTDI FT3K2PQ1"),
                     SerialPortInfo(path: "/dev/cu.SLAB_USBtoUART", description: "CP2102 USB to UART Bridge"),
                     SerialPortInfo(path: "/dev/cu.usbmodem2101"),
                     SerialPortInfo(path: "/dev/cu.debug-console"), SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port")]
        let provider = SerialProfileProvider(ports: { ports })
        let router = Profile(id: "router", type: "serial", name: "Router console", options: ["port": "/dev/cu.usbserial-1420"], color: "#56c8d8")
        for mode in ["dark", "light"] {
            set("appearance.colorSchemeMode", .string(mode))
            for (profile, tag) in [(serial, "serial"), (telnet, "telnet")] {
                for page in ProfileEditorSheet.pages(for: profile.type) where page == .general || page == .advanced {
                    try render(ProfileEditorSnapshot(profile: profile, page: page), NSSize(width: 640, height: 660),
                               "c-editor-\(tag)-\(page.rawValue)-\(mode)")
                }
            }
            try render(SelectorView(config: SerialSelectors.baudSelector { _ in }) { _ in }, SelectorPanel.size, "c3-baud-\(mode)")
            try render(SelectorView(config: SerialSelectors.portSelector(ports: ports) { _ in }) { _ in }, SelectorPanel.size, "c4-ports-\(mode)")
            try render(SelectorView(config: SerialSelectors.portSelector(ports: []) { _ in }) { _ in }, SelectorPanel.size, "c4-empty-\(mode)")
            try render(SelectorView(config: SerialSelectors.connectionsSelector(profiles: [router] + provider.builtinProfiles(),
                                                                                 provider: provider) { _ in }) { _ in },
                       SelectorPanel.size, "c5-serial-\(mode)")
            try render(BaudRatePopover(model: BaudRatePopoverModel(device: "cu.usbserial-1420", current: 115200) { _ in }),
                       NSSize(width: 332, height: 560), "c2-popover-\(mode)")
            try connectionsWindow(mode)
        }
    }

    /// C1b and C9: a split with a serial pane (a pty with hex output) and a telnet pane (a local
    /// raw socket), the chip over the hovered pane and the label on the other; then the telnet
    /// pane disconnected.
    private func connectionsWindow(_ mode: String) throws {
        let pty = try PTYPair()
        let echo = try EchoServer()
        let c = window(NSSize(width: 1280, height: 560))
        defer { TestApp.dispose(c) }
        c.model.openTab(profile: Profile(type: "serial", name: "Router console",
                                         options: ["port": .string(pty.replicaPath), "baudrate": 115200, "outputMode": "hex"]))
        c.model.split(.right, profile: Profile(type: "telnet", name: "Core switch", options: ["host": "127.0.0.1", "port": .int(echo.port)]))
        TestApp.pump(1.2)
        pty.write("Firmware 2.4.1\r\nBuild 0193\r\nOK\r\n> ")
        TestApp.pump(0.6)
        let tab = try XCTUnwrap(c.model.tabs.last)
        let views = tab.orderedPanes.compactMap { c.paneView(for: $0) }
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        views.first?.mouseEntered(with: enter)
        TestApp.pump(0.5)
        try save(try XCTUnwrap(c.window?.contentView), "c1-split-\(mode)")
        tab.orderedPanes.last?.disconnect()
        TestApp.pump(0.8)
        try save(try XCTUnwrap(c.window?.contentView), "c9-disconnected-\(mode)")
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

    func testAccountScreens() async throws {
        for mode in [AccountSheetMode.signIn, .register, .forgotPassword, .recoveryKey("K7QF-9MXA-2PLT-R4WN-8HJD-C3VZ-T6YB-Q1EM")] {
            try render(AccountSheet(mode: mode, dismiss: {}), NSSize(width: 440, height: 520), "account-\(String(describing: mode).prefix(12))")
        }
        try render(KeyFilesSheet(files: [KeyFileCandidate(id: "a", originalPath: "~/.ssh/id_ed25519", isDefaultIdentity: true),
                                         KeyFileCandidate(id: "b", originalPath: "~/.ssh/acme_ci", isDefaultIdentity: false)], dismiss: {}),
                   NSSize(width: 480, height: 320), "account-keyfiles")
        let c = window()
        defer { TestApp.dispose(c) }
        c.model.openSettings(section: .account)
        TestApp.pump(0.6)
        try save(try XCTUnwrap(c.window?.contentView), "settings-account-signedout")
        let account = AppServices.shared.account
        if !account.isSignedIn {
            _ = try await account.register(email: "alex.nguyen@example.com", password: "Correct-Horse-9", keepSignedIn: false)
            await account.finishRegistration()
        }
        TestApp.pump(0.8)
        try save(try XCTUnwrap(c.window?.contentView), "settings-account-signedin")
        try render(AccountPopover(close: {}, openSettings: {}), NSSize(width: 290, height: 300), "account-popover")
        try render(SignOutSheet(dismiss: {}), NSSize(width: 440, height: 300), "account-signout")
        try render(AccountSheet(mode: .restored, dismiss: {}), NSSize(width: 440, height: 420), "account-restored")
        c.model.openSettings(section: .vault)
        TestApp.pump(0.6)
        try save(try XCTUnwrap(c.window?.contentView), "settings-vault")
        await account.signOut(removeSyncedData: false)
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

    /// Phase 5: the main screens in German (Tabby's catalog) and Vietnamese (TabbyMac's).
    func testLocalizedScreens() throws {
        defer { AppServices.shared.config.set("language", .null) }
        for language in ["de-DE", "vi-VN"] {
            AppServices.shared.config.set("language", .string(language))
            let c = window()
            defer { TestApp.dispose(c) }
            TestApp.pump(0.5)
            try save(try XCTUnwrap(c.window?.contentView), "\(language)-start")
            c.model.openTab(profile: TestApp.profile("~/Projects", "sleep 30"))
            c.model.openWelcome()
            TestApp.pump(0.6)
            try save(try XCTUnwrap(c.window?.contentView), "\(language)-welcome")
            for section in SettingsSection.allCases {
                c.model.openSettings(section: section)
                TestApp.pump(0.5)
                try save(try XCTUnwrap(c.window?.contentView), "\(language)-settings-\(section)")
            }
            let serial = Profile(type: "serial", name: "Router console", options: ["port": "/dev/cu.usbserial-1420", "baudrate": 115200])
            for page in ProfileEditorSheet.Page.allCases where page != .ciphers {
                try render(ProfileEditorSnapshot(profile: serial, page: page), NSSize(width: 640, height: 660),
                           "\(language)-editor-serial-\(page.rawValue.replacingOccurrences(of: " ", with: "-"))")
            }
            try render(PasteWarningCard(text: "cd /srv/api\nsudo systemctl restart api") { _, _ in }, NSSize(width: 460, height: 300), "\(language)-card-paste")
            try render(HostKeyPromptCard(host: "prod-web-01.acme.internal:22", keyType: "ssh-ed25519",
                                         fingerprint: "SHA256:qX3m9vT2pKcY8hN1rB7eW4uF6sJ0aL5dZ2gH9xC3oVk") { _ in },
                       NSSize(width: 480, height: 380), "\(language)-card-hostkey")
            try render(SignedOutAccountCard(createAccount: {}, signIn: {}), NSSize(width: 420, height: 220), "\(language)-account-signed-out")
        }
    }
}
#endif
