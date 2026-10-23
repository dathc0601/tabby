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
        let tabby = L10n.Catalog.normalizedKeys(try Self.tabbyMsgids())
        let own = Set(try Self.usedKeys().map(\.text)).filter { !tabby.contains(L10n.Catalog.normalize($0).core) }.sorted()
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

    /// Calls whose literal argument is shown to the user (checked when the literal has a letter
    /// outside `\(…)`), plus any literal that reads as English words ("Show", "Port closed").
    /// `// l10n-ignore` on a line, or `l10n-ignore-file` anywhere in a file, exempts it: key
    /// names, font names, identifiers, log lines.
    static let uiPrefixes = [
        #"\b(Text|Button|Label|Toggle|Picker|Menu|TextField|SecureField|GroupHeader|SettingsRow|SettingsGroup|SettingsPage)\(\s*$"#,
        #"\.help\(\s*$"#,
        #"\bKeycap\(\s*$"#,
        #"\bhint\([^,]*,\s*$"#,
        #"NSMenuItem\(title:\s*$"#,
        #"(?<![.\w])(command|item)\(\s*$"#,
        #"\.(messageText|informativeText)\s*=\s*$"#,
        #"addButton\(withTitle:\s*$"#,
        #"\b(title|subtitle|placeholder|message|detail|footer|confirm|cancel|help|label|text|prompt|group|actionTitle):\s*$"#,
        #"ServiceMessage\.\w+\(\s*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    static let prose = try! NSRegularExpression(pattern: #"^[A-Z][a-z’']*[.,:!?…]?(?:[ \x{00A0}]\S+)*$"#)
    static let wrapped = try! NSRegularExpression(pattern: #"\b(L|Lkey)\(\s*$"#)
    static let skippedLines = try! NSRegularExpression(pattern: #"NSLog\(|(?<![.\w])print\(|fatalError\(|assert|precondition\(|\.custom\(|NSFont\(name:|os_log|Logger\(|Notification\.Name\(|forResource:|setFrameAutosaveName|DispatchQueue\(label|identifier:"#)

    /// Files not swept yet. Each sweep task (5.4a–e) removes its files; at the end of phase 5
    /// the list is empty.
    static let notYetSwept: Set<String> = [
        "Sources/TabbyCore/ColorSchemes/ColorScheme.swift",
        "Sources/TabbyCore/Config/ConfigPaths.swift",
        "Sources/TabbyCore/Config/ConfigStore.swift",
        "Sources/TabbyCore/Config/ConfigValue.swift",
        "Sources/TabbyCore/Config/Migrations.swift",
        "Sources/TabbyCore/Hotkeys/Keystroke.swift",
        "Sources/TabbyCore/Profiles/ProfileProvider.swift",
        "Sources/TabbyCore/Profiles/ProfileRegistry.swift",
        "Sources/TabbyCore/Profiles/StreamProcessing.swift",
        "Sources/TabbyCore/Serial/SerialProfileProvider.swift",
        "Sources/TabbyCore/SSH/SSHConfigGenerator.swift",
        "Sources/TabbyCore/SSH/SSHConfigParser.swift",
        "Sources/TabbyCore/Telnet/TelnetProfileProvider.swift",
        "Sources/TabbySerial/SerialPort.swift",
        "Sources/TabbySerial/SerialSession.swift",
        "Sources/TabbySSH/SSHSession.swift",
        "Sources/TabbySSHLib/LibSSHSession.swift",
        "Sources/TabbySSHLib/PortForwards.swift",
        "Sources/TabbySSHLib/SFTPClient.swift",
        "Sources/TabbySSHLib/SSHConnection.swift",
        "Sources/TabbySSHLib/SSHConnectionTest.swift",
        "Sources/TabbySSHLib/SSHConnector.swift",
        "Sources/TabbyTelnet/TelnetSession.swift",
        "Sources/TabbyTerminal/PTYProcess.swift",
        "Sources/TabbyTerminal/SwiftTermEngine.swift",
        "Sources/TabbyTerminal/TerminalPane.swift",
        "Sources/TabbyTerminal/TerminalSettings.swift",
    ]

    func testUserVisibleTextGoesThroughL() throws {
        var offenders: [String: [String]] = [:]
        for file in try Self.swiftFiles() {
            let hits = try Self.rawLiterals(in: file)
            if !hits.isEmpty { offenders[Self.relative(file), default: []] += hits }
        }
        for (file, hits) in offenders.sorted(by: { $0.key < $1.key }) where !Self.notYetSwept.contains(file) {
            XCTFail("\(file): \(hits.count) literal(s) without L(): \(hits.prefix(4).joined(separator: " | "))")
        }
        for file in Self.notYetSwept.sorted() where offenders[file] == nil {
            XCTFail("\(file) has no raw literals left: remove it from notYetSwept")
        }
    }

    func testTheLiteralScannerFindsShownTextOnly() {
        func hits(_ line: String) -> [String] { Self.rawLiterals(inLines: [line]).map { $0.components(separatedBy: ": ").dropFirst().joined(separator: ": ") } }
        XCTAssertEqual(hits(#"Text("Hello")"#), ["Hello"])
        XCTAssertEqual(hits(#"Text(L("Hello"))"#), [])
        XCTAssertEqual(hits(#"item(running ? "Disconnect" : "Reconnect", id)"#), ["Disconnect", "Reconnect"])
        XCTAssertEqual(hits(#"let url = "https://example.com" // A comment"#), [])
        XCTAssertEqual(hits(#"title: "user@host""#), ["user@host"])
        XCTAssertEqual(hits(#"Text("\(a ?? "Fallback text") items")"#), [#"\(a ?? "Fallback text") items"#])
        XCTAssertEqual(hits(#"NSLog("Could not save")"#), [])
        XCTAssertEqual(hits(#"Button { export.print(key) } label: { Label("Print", systemImage: "printer") }"#), ["Print"])
        XCTAssertEqual(hits(#"x = "Menlo" // l10n-ignore"#), [])
        XCTAssertEqual(hits(#"Text("\(count)")"#), [])
        XCTAssertEqual(hits(#"let id = "new-tab""#), [])
        XCTAssertEqual(hits(#"case .connecting: return "Connecting…""#), ["Connecting…"])
        XCTAssertEqual(hits(#"let s = "\(a) · \(b)""#), [], "no words outside the interpolations")
        XCTAssertEqual(hits(#"Keycap("esc close")"#), ["esc close"])
        XCTAssertEqual(hits(#"hint("↩", "open")"#), ["open"])
        XCTAssertEqual(hits(#"return "A folder name cannot be empty""#), ["A folder name cannot be empty"])
        XCTAssertEqual(hits(#"Button(L("Close")) { actions.command("close-other-tabs", tab) }"#), [], "a method's id argument")
        XCTAssertEqual(hits(#"menu.addItem(command("New Tab", "new-tab"))"#), ["New Tab"])
        XCTAssertEqual(hits(#"message = "Imported. Some changes apply""#), ["Imported. Some changes apply"])
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
        let text = try String(contentsOf: file, encoding: .utf8)
        if text.contains("l10n-ignore-file") { return [] }
        return rawLiterals(inLines: text.components(separatedBy: "\n"))
    }

    static func rawLiterals(inLines lines: [String]) -> [String] {
        var hits: [String] = []
        var inMultiline = false
        for (n, line) in lines.enumerated() {
            if line.contains("\"\"\"") { inMultiline.toggle(); continue }
            if inMultiline || line.contains("l10n-ignore") { continue }
            let ns = line as NSString
            if skippedLines.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) != nil { continue }
            for (literal, before) in literals(in: line) {
                let range = NSRange(location: 0, length: (before as NSString).length)
                if wrapped.firstMatch(in: before, range: range) != nil { continue }
                let shown = uiPrefixes.contains { $0.firstMatch(in: before, range: range) != nil } && hasWords(literal)
                let plain = literal.replacingOccurrences(of: #"\\\([^)]*\)"#, with: "0", options: .regularExpression)
                let looksLikeProse = plain.count > 2 && prose.firstMatch(in: plain, range: NSRange(location: 0, length: (plain as NSString).length)) != nil
                if shown || looksLikeProse { hits.append("\(n + 1): \(literal)") }
            }
        }
        return hits
    }

    /// The string literals of one line with the code before each, up to a `//` comment.
    static func literals(in line: String) -> [(text: String, before: String)] {
        let chars = Array(line)
        var result: [(String, String)] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break }
            guard c == "\"" else { i += 1; continue }
            let start = i
            var j = i + 1
            var text = ""
            var depth = 0
            while j < chars.count {
                let d = chars[j]
                if depth == 0 {
                    if d == "\\" {
                        text.append(d)
                        if j + 1 < chars.count { text.append(chars[j + 1]); if chars[j + 1] == "(" { depth = 1 } }
                        j += 2
                        continue
                    }
                    if d == "\"" { break }
                    text.append(d); j += 1
                } else {
                    if d == "\"" {
                        text.append(d); j += 1
                        while j < chars.count && chars[j] != "\"" {
                            if chars[j] == "\\" { text.append(chars[j]); j += 1 }
                            if j < chars.count { text.append(chars[j]); j += 1 }
                        }
                        if j < chars.count { text.append(chars[j]); j += 1 }
                        continue
                    }
                    if d == "(" { depth += 1 } else if d == ")" { depth -= 1 }
                    text.append(d); j += 1
                }
            }
            result.append((text, String(chars[0..<start])))
            i = j + 1
        }
        return result
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
