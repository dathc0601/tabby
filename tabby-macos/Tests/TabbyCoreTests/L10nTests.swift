import XCTest
@testable import TabbyCore

/// Phase 5: Tabby's gettext catalogs (`../locale/*.po`), the language list and `L()`.
final class L10nTests: XCTestCase {
    override func tearDown() {
        L10n.load(language: nil)
        super.tearDown()
    }

    // MARK: .po parsing

    func testParsesEntriesContinuationLinesAndEscapes() {
        let po = """
        msgid ""
        msgstr ""
        "Content-Type: text/plain; charset=UTF-8\\n"

        #: tabby-local/src/components/terminalTab.component.ts:113
        msgid "\\"{command}\\" is still running. Close?"
        msgstr "\\"{command}\\" läuft noch. Schließen?"

        msgid ""
        "A long "
        "message"
        msgstr "Eine lange "
        "Nachricht\\nmit Zeile\\tund \\\\"
        """
        let c = POCatalog.parse(po)
        XCTAssertEqual(c["\"{command}\" is still running. Close?"], "\"{command}\" läuft noch. Schließen?")
        XCTAssertEqual(c["A long message"], "Eine lange Nachricht\nmit Zeile\tund \\")
        XCTAssertEqual(c.count, 2, "the header entry is not a string: \(c)")
    }

    func testUntranslatedAndFuzzyEntriesAreLeftOut() {
        let po = """
        msgid "Abort all"
        msgstr ""

        #, fuzzy
        msgid "Accept"
        msgstr "Akzeptieren?"

        #, c-format
        msgid "Close"
        msgstr "Schließen"
        """
        XCTAssertEqual(POCatalog.parse(po), ["Close": "Schließen"])
    }

    func testContextAndPluralEntries() {
        let po = """
        msgctxt "[Dynamic] port forwarding"
        msgid "Dynamic"
        msgstr "Dynamisch"

        msgid "Dynamic"
        msgstr "Veränderlich"

        msgid "{n} tab"
        msgid_plural "{n} tabs"
        msgstr[0] "{n} Tab"
        msgstr[1] "{n} Tabs"
        """
        let c = POCatalog.parse(po)
        XCTAssertEqual(c[POCatalog.key("Dynamic", context: "[Dynamic] port forwarding")], "Dynamisch")
        XCTAssertEqual(c["Dynamic"], "Veränderlich")
        XCTAssertEqual(c["{n} tab"], "{n} Tab", "Tabby reads msgstr[0]")
    }

    // MARK: Languages

    func testTheLanguageListIsTabbysPlusVietnamese() {
        XCTAssertEqual(Languages.all.map(\.code), [
            "af-ZA", "id-ID", "cs-CZ", "da-DK", "de-DE", "en-GB", "en-US", "es-ES", "fr-FR", "hr-HR",
            "it-IT", "pl-PL", "pt-PT", "pt-BR", "sv-SE", "tr-TR", "vi-VN", "bg-BG", "ru-RU", "sr-SP",
            "uk-UA", "ja-JP", "ko-KR", "zh-CN", "zh-TW",
        ])
        XCTAssertEqual(Languages.all.first { $0.code == "de-DE" }?.name, "Deutsch")
        XCTAssertEqual(Languages.all.first { $0.code == "vi-VN" }?.name, "Tiếng Việt")
        XCTAssertEqual(Languages.all.first { $0.code == "zh-CN" }?.name, "中文（简体）")
    }

    func testAConfiguredLanguageWins() {
        XCTAssertEqual(Languages.resolve(configured: "ja-JP", preferred: ["de-DE"]), "ja-JP")
        XCTAssertEqual(Languages.resolve(configured: "xx-YY", preferred: ["de-DE"]), "de-DE", "unknown → automatic")
        XCTAssertEqual(Languages.resolve(configured: "", preferred: ["fr-FR"]), "fr-FR")
    }

    func testAutomaticFollowsThePreferredLanguagesInOrder() {
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["en-US"]), "en-US")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["de-AT", "en-US"]), "de-DE",
                       "the first preferred language wins, by language when the region differs")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["pt-BR"]), "pt-BR")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["pt-AO"]), "pt-PT")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["zh-Hans-CN"]), "zh-CN")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["zh-Hant-TW"]), "zh-TW")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["zh-HK"]), "zh-TW")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["sr-Cyrl-RS"]), "sr-SP")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["vi"]), "vi-VN")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["en-AU"]), "en-US")
        XCTAssertEqual(Languages.resolve(configured: nil, preferred: ["de_CH"]), "de-DE")
        XCTAssertNil(Languages.resolve(configured: nil, preferred: ["fi-FI", "nb-NO"]))
        XCTAssertNil(Languages.resolve(configured: nil, preferred: []))
    }

    // MARK: L()

    func testLReturnsTheKeyWithoutACatalogAndFillsPlaceholders() {
        L10n.load(language: nil)
        XCTAssertEqual(L("Abort all"), "Abort all")
        XCTAssertEqual(L("Disconnect from {host}?", ["host": "switch.lan"]), "Disconnect from switch.lan?")
        XCTAssertEqual(L("Tab {number}", ["number": 12_000]), "Tab 12000", "numbers are not grouped")
        XCTAssertEqual(L("{a} and {b}", ["a": 1]), "1 and {b}", "a missing value leaves the placeholder")
    }

    func testTheAppsOwnCatalogComesBeforeTabbys() {
        let catalog = L10n.Catalog(layers: [["Close": "Đóng"], ["Close": "Schließen", "Abort all": "Alles abbrechen"]])
        XCTAssertEqual(catalog.lookup("Close"), "Đóng")
        XCTAssertEqual(catalog.lookup("Abort all"), "Alles abbrechen")
        XCTAssertNil(catalog.lookup("Nope"))
    }

    /// Menu items end in "…" and TabbyMac uses sentence case where Tabby's msgid may not; the
    /// translation is still Tabby's.
    func testCaseAndATrailingEllipsisOrColonDoNotHideATranslation() {
        let catalog = L10n.Catalog(layers: [["Settings": "Einstellungen", "New Tab": "Neuer Tab", "Rename...": "Umbenennen...",
                                              "Host:": "Host:", "Close": "Schließen"]])
        XCTAssertEqual(catalog.lookup("Settings…"), "Einstellungen…")
        XCTAssertEqual(catalog.lookup("New tab"), "Neuer Tab")
        XCTAssertEqual(catalog.lookup("Rename…"), "Umbenennen…")
        XCTAssertEqual(catalog.lookup("Host"), "Host")
        XCTAssertEqual(catalog.lookup("Close:"), "Schließen:")
        XCTAssertEqual(catalog.lookup("Close"), "Schließen", "an exact match first")
        XCTAssertNil(catalog.lookup("Close tab"))
        XCTAssertTrue(L10n.Catalog.normalizedKeys(["New Tab", "Settings..."]).contains(L10n.Catalog.normalize("settings…").core))
    }

    func testTheBundledGermanCatalogTranslates() {
        L10n.load(language: "de-DE")
        XCTAssertEqual(L10n.language, "de-DE")
        XCTAssertEqual(L("Abort all"), "Alles abbrechen")
        XCTAssertEqual(L("\"{command}\" is still running. Close?", ["command": "vim"]), "\"vim\" läuft noch. Schließen?")
        L10n.load(language: nil)
        XCTAssertNil(L10n.language)
        XCTAssertEqual(L("Abort all"), "Abort all")
    }

    func testEveryTabbyCatalogIsBundledAndParses() {
        for language in Languages.all where language.code != "vi-VN" {
            let entries = L10n.bundledEntries(language.code, source: .tabby)
            XCTAssertFalse(entries.isEmpty, "\(language.code) has no bundled Tabby catalog")
            if language.code != "en-US" && language.code != "en-GB" {
                XCTAssertGreaterThan(entries.count, 400, language.code)
            }
        }
    }

    // MARK: Plural

    func testPluralPicksOneOrOtherAndTranslatesBoth() {
        XCTAssertEqual(Plural.count(1, one: "1 profile", other: "{n} profiles"), "1 profile")
        XCTAssertEqual(Plural.count(3, one: "1 profile", other: "{n} profiles"), "3 profiles")
        XCTAssertEqual(Plural.count(0, one: "1 profile", other: "{n} profiles"), "0 profiles")
        L10n.install(L10n.Catalog(layers: [["{n} profiles": "{n} hồ sơ", "1 profile": "1 hồ sơ"]]), language: "vi-VN")
        XCTAssertEqual(Plural.count(4, one: "1 profile", other: "{n} profiles"), "4 hồ sơ")
    }
}
