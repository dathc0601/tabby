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

    func testSettingsSectionsShowTranslatedTitlesAndStillMatchEnglish() {
        AppServices.shared.config.set("language", .string("de-DE"))
        XCTAssertEqual(SettingsSection.application.title, "Anwendung")
        XCTAssertTrue(SettingsSection.application.matches("anwend"))
        XCTAssertTrue(SettingsSection.application.matches("application"), "English still finds the page")
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
