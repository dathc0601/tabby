#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Phase 5: `language` in config.yaml picks the catalog; the change applies live.
@MainActor
final class LanguageTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    override func tearDown() {
        AppServices.shared.config.set("language", .null)
        super.tearDown()
    }

    func testTestsRunInEnglish() {
        XCTAssertEqual(AppServices.preferredLanguages(), ["en-US"], "TestApp pins the preferred language")
        XCTAssertEqual(L("Application"), "Application")
    }

    func testTheLanguageFollowsTheConfig() {
        let services = AppServices.shared
        services.config.set("language", .string("de-DE"))
        XCTAssertEqual(services.language, "de-DE")
        XCTAssertEqual(L10n.language, "de-DE")
        XCTAssertEqual(L("Abort all"), "Alles abbrechen")
        services.config.set("language", .null)
        XCTAssertEqual(services.language, "en-US", "Automatic follows the (pinned) system language")
        XCTAssertEqual(L("Abort all"), "Abort all")
    }

    func testALanguageChangeRebuildsTheMenuBar() {
        MainMenu.install()
        let before = NSApp.mainMenu
        AppServices.shared.config.set("terminal.scrollback", .int(4321))
        XCTAssertTrue(NSApp.mainMenu === before, "other settings leave the menu bar alone")
        AppServices.shared.config.set("language", .string("fr-FR"))
        XCTAssertFalse(NSApp.mainMenu === before, "the menu bar is rebuilt in the new language")
        AppServices.shared.config.set("terminal.scrollback", .null)
    }

    /// 5.4a: menus, prompts and alerts go through the catalogs.
    func testTheMenuBarAndAlertsAreTranslated() {
        MainMenu.install()
        AppServices.shared.config.set("language", .string("de-DE"))
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        XCTAssertNotNil(appMenu?.items.first { $0.title == "Einstellungen…" }, "\(appMenu?.items.map(\.title) ?? [])")
        XCTAssertEqual(AppDelegate.quitAlert(warnings: []).buttons.last?.title, "Abbrechen")
    }

    /// 5.4b: settings pages, hotkey names and profile types.
    func testHotkeyNamesAndProfileTypesAreTranslated() throws {
        AppServices.shared.config.set("language", .string("de-DE"))
        let newTab = try XCTUnwrap(HotkeyCatalog.byId["new-tab"])
        XCTAssertEqual(newTab.name, "New tab", "the English name stays for config and search")
        XCTAssertEqual(newTab.title, "Neuer Tab")
        XCTAssertEqual(HotkeyCatalog.byId["pane-nav-3"]?.title, "Fokusbereich 3")
        XCTAssertEqual(HotkeyCatalog.byId["pane-nav-3"]?.name, "Focus pane 3")
        XCTAssertEqual(ProfileTypes.title("local"), "Lokales Terminal")
    }

    /// 5.4c: the account texts, plurals included, come from the catalog (Tabby's catalogs
    /// have none of them; Vietnamese does).
    func testAccountTextsAndPluralsComeFromTheCatalog() {
        defer { L10n.load(language: AppServices.shared.language) }
        L10n.install(L10n.Catalog(layers: [[
            "{n} profiles": "{n} hồ sơ",
            "{profiles} on this Mac will upload next": "{profiles} trên máy Mac này sẽ được tải lên tiếp theo",
            "Start syncing": "Bắt đầu đồng bộ",
        ]]), language: "vi-VN")
        let texts = RecoveryKeyTexts(purpose: .signUp, profiles: 3)
        XCTAssertEqual(texts.footer, "3 hồ sơ trên máy Mac này sẽ được tải lên tiếp theo")
        XCTAssertEqual(texts.confirm, "Bắt đầu đồng bộ")
    }

    /// 5.4d: views (chip, selector footer) read the catalog.
    func testViewTextsComeFromTheCatalog() {
        defer { L10n.load(language: AppServices.shared.language) }
        L10n.install(L10n.Catalog(layers: [[
            "Connecting…": "Đang kết nối…",
            "Reconnecting {attempt}/{total}": "Đang kết nối lại {attempt}/{total}",
            "{profiles} profiles · {commands} commands": "{profiles} hồ sơ · {commands} lệnh",
        ]]), language: "vi-VN")
        XCTAssertEqual(ConnectionChip.label(.connecting), "Đang kết nối…")
        XCTAssertEqual(ConnectionChip.label(.reconnecting(attempt: 2, of: 5)), "Đang kết nối lại 2/5")
        if let hint = SelectorPanel.profilesAndCommandsHint {
            XCTAssertTrue(hint.contains(" hồ sơ · "), hint)
        }
    }

    func testSettingsSectionsShowTranslatedTitlesAndStillMatchEnglish() {
        AppServices.shared.config.set("language", .string("de-DE"))
        XCTAssertEqual(SettingsSection.application.title, "Anwendung")
        XCTAssertTrue(SettingsSection.application.matches("anwend"))
        XCTAssertTrue(SettingsSection.application.matches("application"), "English still finds the page")
    }

    /// M10: after a live switch the settings sidebar, the page's path row and the tab title
    /// kept the old language until clicked (views that read no observed state are not
    /// re-rendered). A switched window must look like one opened in the new language.
    func testALiveSwitchRedrawsEveryTextOfTheSettingsTab() throws {
        func shot(_ c: MainWindowController) throws -> Data {
            let view = try XCTUnwrap(c.window?.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            return try XCTUnwrap(rep.tiffRepresentation)
        }
        func settingsWindow() -> MainWindowController {
            let c = WindowManager.shared.newWindow(openDefaultTab: false)
            c.window?.setContentSize(NSSize(width: 1100, height: 700))
            c.model.openSettings(section: .application)
            TestApp.pump(0.6)
            return c
        }
        let switched = settingsWindow()
        defer { TestApp.dispose(switched) }
        AppServices.shared.config.set("language", .string("de-DE"))
        TestApp.pump(0.6)
        let live = try shot(switched)
        let fresh = settingsWindow()
        defer { TestApp.dispose(fresh) }
        let expected = try shot(fresh)
        if live != expected, let dir = ProcessInfo.processInfo.environment["TABBYMAC_SNAPSHOT_DIR"] {
            try? live.write(to: URL(fileURLWithPath: dir).appendingPathComponent("language-live.tiff"))
            try? expected.write(to: URL(fileURLWithPath: dir).appendingPathComponent("language-fresh.tiff"))
        }
        XCTAssertTrue(live == expected, "the switched window still shows text in the old language")
    }

    func testThePickerOffersAutomaticThenEveryLanguage() {
        let options = LanguagePicker.options
        XCTAssertEqual(options.first?.tag, "")
        XCTAssertEqual(options.first?.name, "Automatic")
        XCTAssertEqual(options.dropFirst().map(\.tag), Languages.all.map(\.code))
        XCTAssertTrue(options.contains { $0.name == "Tiếng Việt" })
    }
}
#endif
