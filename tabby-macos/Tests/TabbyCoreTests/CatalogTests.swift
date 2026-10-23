import XCTest
@testable import TabbyCore

/// Phase 5 guards over the catalogs and the sources:
/// - every `L("…")` key is in Tabby's catalogs or in TabbyMac's template `tabbymac.pot`, and
///   the template is current (`scripts/l10n-extract.sh` rewrites it through this test);
/// - TabbyMac's own translations keep every placeholder;
/// - no user-visible literal skips `L()` (outside the files still being swept).
final class CatalogTests: XCTestCase {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sources = packageRoot.appendingPathComponent("Sources")
    static let locale = sources.appendingPathComponent("TabbyCore/Resources/locale")
    static let template = locale.appendingPathComponent("tabbymac/tabbymac.pot")

    // MARK: Placeholders

    func testATranslationThatRenamesAPlaceholderFallsBackToEnglish() {
        let po = """
        msgid "Tab {number}"
        msgstr "Flik {nummer}"

        msgid "New tab: {profile}"
        msgstr "Ny flik: {profile}"
        """
        XCTAssertEqual(POCatalog.parse(po), ["New tab: {profile}": "Ny flik: {profile}"])
        XCTAssertEqual(POCatalog.placeholders("{a} and {b_2}, not { c } or {}"), ["a", "b_2"])
    }

    func testTheAppsOwnTranslationsKeepEveryPlaceholder() throws {
        for url in try Self.appCatalogs() {
            for entry in POCatalog.entries(try String(contentsOf: url, encoding: .utf8)) where !entry.translation.isEmpty {
                XCTAssertTrue(POCatalog.placeholders(entry.translation).isSubset(of: POCatalog.placeholders(entry.id)),
                              "\(url.lastPathComponent): \(entry.id) → \(entry.translation)")
            }
        }
    }

    // MARK: Keys

    func testKeysAreStaticText() throws {
        for key in try Self.usedKeys() {
            XCTAssertFalse(key.text.contains("\\("), "\(key.file): L() keys cannot interpolate; use {name} placeholders: \(key.text)")
        }
    }

    /// Rewrites the template with `TABBYMAC_WRITE_POT=1` (`scripts/l10n-extract.sh`).
    func testTheAppCatalogTemplateIsCurrent() throws {
        let tabby = try Self.tabbyMsgids()
        let own = Set(try Self.usedKeys().map(\.text)).subtracting(tabby).sorted()
        let expected = Self.pot(own)
        if ProcessInfo.processInfo.environment["TABBYMAC_WRITE_POT"] == "1" {
            try FileManager.default.createDirectory(at: Self.template.deletingLastPathComponent(), withIntermediateDirectories: true)
            try expected.write(to: Self.template, atomically: true, encoding: .utf8)
            return
        }
        let current = (try? String(contentsOf: Self.template, encoding: .utf8)) ?? ""
        XCTAssertEqual(current, expected, "tabbymac.pot is out of date: run scripts/l10n-extract.sh")
    }

    // MARK: Raw literals

    /// Calls whose literal text is shown to the user. A literal counts when it has a letter
    /// outside `\(…)`; `// l10n-ignore` on the line exempts it (identifiers, sample input).
    static let uiPatterns = [
        #"\b(Text|Button|Label|Toggle|Picker|Menu|TextField|SecureField|GroupHeader|SettingsRow|SettingsGroup|SettingsPage)\(\s*""#,
        #"\.help\(\s*""#,
        #"NSMenuItem\(title:\s*""#,
        #"\b(command|item)\(\s*""#,
        #"\.(messageText|informativeText)\s*=\s*""#,
        #"addButton\(withTitle:\s*""#,
        #"\b(title|subtitle|placeholder|message|detail|footer|confirm|cancel|help|label|text|prompt):\s*""#,
        #"ServiceMessage\.\w+\(\s*""#,
    ]

    /// Files not swept yet. Each sweep task (5.4a–e) removes its files; at the end of phase 5
    /// the list is empty.
    static let notYetSwept: Set<String> = [
        "Sources/TabbyApp/Account/AccountSettingsView.swift",
        "Sources/TabbyApp/Account/AccountViews.swift",
        "Sources/TabbyApp/App/AppDelegate.swift",
        "Sources/TabbyApp/App/MainMenu.swift",
        "Sources/TabbyApp/Commands/Commands.swift",
        "Sources/TabbyApp/Commands/SerialSelectors.swift",
        "Sources/TabbyApp/Prompts/KeyboardInteractivePanel.swift",
        "Sources/TabbyApp/Prompts/LibSSHPromptPresenter.swift",
        "Sources/TabbyApp/Prompts/PromptCards.swift",
        "Sources/TabbyApp/Prompts/Prompts.swift",
        "Sources/TabbyApp/Settings/ColorSchemeSettingsView.swift",
        "Sources/TabbyApp/Settings/ConfigFileSettingsView.swift",
        "Sources/TabbyApp/Settings/HotkeysSettingsView.swift",
        "Sources/TabbyApp/Settings/ProfilesSettingsView.swift",
        "Sources/TabbyApp/Settings/SettingsView.swift",
        "Sources/TabbyApp/Split/SplitOverlays.swift",
        "Sources/TabbyApp/Split/SplitTreeView.swift",
        "Sources/TabbyApp/Views/BaudRatePopover.swift",
        "Sources/TabbyApp/Views/Components/ChromeControls.swift",
        "Sources/TabbyApp/Views/ConnectionChip.swift",
        "Sources/TabbyApp/Views/PortsPopover.swift",
        "Sources/TabbyApp/Views/SearchBarView.swift",
        "Sources/TabbyApp/Views/SelectorPanel.swift",
        "Sources/TabbyApp/Views/SFTPPanelController.swift",
        "Sources/TabbyApp/Views/SFTPPanelView.swift",
        "Sources/TabbyApp/Views/StartPageView.swift",
        "Sources/TabbyApp/Views/TabBarView.swift",
        "Sources/TabbyApp/Views/Toasts.swift",
        "Sources/TabbyApp/Views/Transfers.swift",
        "Sources/TabbyApp/Views/WelcomeView.swift",
        "Sources/TabbyApp/Window/MainWindowController.swift",
        "Sources/TabbyCore/Profiles/ProfileRegistry.swift",
        "Sources/TabbyCore/Profiles/StreamProcessing.swift",
        "Sources/TabbySerial/SerialPort.swift",
        "Sources/TabbySerial/SerialSession.swift",
        "Sources/TabbySSHLib/LibSSHSession.swift",
        "Sources/TabbyTelnet/TelnetSession.swift",
        "Sources/TabbyTerminal/PTYProcess.swift",
        "Sources/TabbyTerminal/SwiftTermEngine.swift",
    ]

    func testUserVisibleTextGoesThroughL() throws {
        var offenders: [String: [String]] = [:]
        for file in try Self.swiftFiles() {
            let hits = try Self.rawLiterals(in: file)
            if !hits.isEmpty { offenders[Self.relative(file), default: []] += hits }
        }
        for (file, hits) in offenders.sorted(by: { $0.key < $1.key }) where !Self.notYetSwept.contains(file) {
            XCTFail("\(file): \(hits.count) literal(s) without L(): \(hits.prefix(3).joined(separator: " | "))")
        }
        for file in Self.notYetSwept.sorted() where offenders[file] == nil {
            XCTFail("\(file) has no raw literals left: remove it from notYetSwept")
        }
    }

    // MARK: Helpers

    struct Key: Hashable { let text: String; let file: String }

    static func swiftFiles() throws -> [URL] {
        let skipped = ["TabbyAskpass", "TabbyIPC", "TabbyMacDev", "CLibSSH", "TabbySyncProtocol", "TabbyCore/L10n", "Resources"]
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let path = relative(url)
            if skipped.contains(where: { path.hasPrefix("Sources/\($0)") }) { continue }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    static func relative(_ url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(packageRoot.standardizedFileURL.path.count + 1))
    }

    /// `L("…")`, `Lkey("…")` and both forms of `Plural.count(…, one: "…", other: "…")`.
    static func usedKeys() throws -> [Key] {
        let regexes = [#"\bL\(\s*"((?:[^"\\]|\\.)*)""#, #"\bLkey\(\s*"((?:[^"\\]|\\.)*)""#,
                       #"\bone:\s*"((?:[^"\\]|\\.)*)"\s*,\s*other:\s*"((?:[^"\\]|\\.)*)""#]
            .map { try! NSRegularExpression(pattern: $0) }
        var keys: [Key] = []
        for file in try swiftFiles() + [sources.appendingPathComponent("TabbyCore/L10n/L10n.swift")] {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for regex in regexes {
                for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                        keys.append(Key(text: unescape(ns.substring(with: match.range(at: group))), file: relative(file)))
                    }
                }
            }
        }
        return keys.filter { !$0.text.isEmpty }
    }

    static func unescape(_ literal: String) -> String {
        var out = ""
        var it = literal.makeIterator()
        while let ch = it.next() {
            guard ch == "\\" else { out.append(ch); continue }
            switch it.next() {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "(": out.append("\\(")
            case let other?: out.append("\\"); out.append(other)
            case nil: out.append("\\")
            }
        }
        return out
    }

    static func tabbyMsgids() throws -> Set<String> {
        let dir = locale.appendingPathComponent("tabby")
        var ids: Set<String> = []
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where url.pathExtension == "po" {
            for entry in POCatalog.entries(try String(contentsOf: url, encoding: .utf8)) where entry.context == nil && !entry.id.isEmpty {
                ids.insert(entry.id)
            }
        }
        return ids
    }

    static func appCatalogs() throws -> [URL] {
        let dir = locale.appendingPathComponent("tabbymac")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "po" }.sorted { $0.path < $1.path }
    }

    static func pot(_ ids: [String]) -> String {
        var out = """
        # TabbyMac's own strings: those not in Tabby's catalogs (../locale). Generated by
        # scripts/l10n-extract.sh from the L("…") keys in Sources/; do not edit by hand.
        msgid ""
        msgstr ""
        "Content-Type: text/plain; charset=UTF-8\\n"

        """
        for id in ids {
            out += "\nmsgid \(quote(id))\nmsgstr \"\"\n"
        }
        return out
    }

    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\t", with: "\\t") + "\""
    }

    static func rawLiterals(in file: URL) throws -> [String] {
        let regexes = uiPatterns.map { try! NSRegularExpression(pattern: $0) }
        var hits: [String] = []
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        for line in lines where !line.contains("l10n-ignore") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            let ns = line as NSString
            for regex in regexes {
                for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    let start = match.range.location + match.range.length
                    let literal = readLiteral(ns.substring(from: start))
                    if hasWords(literal) { hits.append(literal) }
                }
            }
        }
        return hits
    }

    /// The literal's text up to its closing quote.
    static func readLiteral(_ rest: String) -> String {
        var out = ""
        var escaped = false
        var depth = 0
        for ch in rest {
            if escaped {
                if ch == "(" { depth += 1 }
                out.append(ch); escaped = false; continue
            }
            if ch == "\\" { out.append(ch); escaped = true; continue }
            if depth > 0 {
                if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
                out.append(ch); continue
            }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out
    }

    /// Letters outside `\(…)` interpolations.
    static func hasWords(_ literal: String) -> Bool {
        var depth = 0
        var previous: Character?
        for ch in literal {
            if previous == "\\" && ch == "(" { depth += 1 }
            else if depth > 0 && ch == "(" { depth += 1 }
            else if depth > 0 && ch == ")" { depth -= 1 }
            else if depth == 0 && previous != "\\" && ch.isLetter { return true }
            previous = ch
        }
        return false
    }
}
