import XCTest
@testable import TabbyCore

/// Phase 6: "Copy with formatting" (Tabby's `terminal.copyAsHTML`, xterm's serialize addon)
/// and double-click word selection with `terminal.wordSeparator`.
final class TerminalTextTests: XCTestCase {
    let scheme = ColorScheme(name: "Test", foreground: "#cccccc", background: "#111111", cursor: "#ffffff",
                             colors: ["#000000", "#aa0000", "#00aa00", "#aaaa00", "#0000aa", "#aa00aa", "#00aaaa", "#aaaaaa",
                                      "#555555", "#ff5555", "#55ff55", "#ffff55", "#5555ff", "#ff55ff", "#55ffff", "#ffffff"])

    func cells(_ text: String, _ style: StyledCell = StyledCell(text: "")) -> [StyledCell] {
        text.map { var c = style; c.text = String($0); return c }
    }

    func render(_ lines: [[StyledCell]], brightBold: Bool = true) -> String {
        TerminalHTML.render(lines: lines, scheme: scheme, fontFamily: "Menlo", brightBold: brightBold)
    }

    func testThePreCarriesTheSchemeAndFont() {
        let html = render([cells("hi")])
        XCTAssertTrue(html.hasPrefix("<pre style=\"background-color:#111111;color:#cccccc;font-family:'Menlo',monospace;\">"), html)
        XCTAssertTrue(html.hasSuffix("</pre>"), html)
        XCTAssertTrue(html.contains(">hi<"), html)
    }

    func testRunsOfOneStyleShareASpan() {
        var red = StyledCell(text: "")
        red.foreground = .ansi(1)
        let html = render([cells("ab", red) + cells("cd")])
        XCTAssertTrue(html.contains("<span style=\"color:#aa0000;\">ab</span>"), html)
        XCTAssertTrue(html.contains("<span>cd</span>") || html.contains(">cd<"), html)
        XCTAssertEqual(html.components(separatedBy: "#aa0000").count, 2, "one span for the run")
    }

    func testColours() {
        func colour(_ c: CellColor, bold: Bool = false, brightBold: Bool = true) -> String {
            var cell = StyledCell(text: "x")
            cell.foreground = c
            cell.bold = bold
            return render([[cell]], brightBold: brightBold)
        }
        XCTAssertTrue(colour(.ansi(9)).contains("color:#ff5555;"))
        XCTAssertTrue(colour(.ansi(1), bold: true).contains("color:#ff5555;"), "bold uses the bright colour")
        XCTAssertTrue(colour(.ansi(1), bold: true, brightBold: false).contains("color:#aa0000;"))
        XCTAssertTrue(colour(.ansi(196)).contains("color:#ff0000;"), "the 6×6×6 cube")
        XCTAssertTrue(colour(.ansi(16)).contains("color:#000000;"))
        XCTAssertTrue(colour(.ansi(244)).contains("color:#808080;"), "the grey ramp")
        XCTAssertTrue(colour(.rgb(1, 2, 255)).contains("color:#0102ff;"))
        XCTAssertFalse(colour(.default).contains("<span style=\"color"), "the default colour is the pre's")
    }

    func testStylesAndInverse() {
        var cell = StyledCell(text: "x")
        cell.bold = true
        cell.italic = true
        cell.underline = true
        cell.strikethrough = true
        cell.dim = true
        let html = render([[cell]], brightBold: false)
        for part in ["font-weight:bold;", "font-style:italic;", "text-decoration:underline line-through;", "opacity:0.5;"] {
            XCTAssertTrue(html.contains(part), "\(part) in \(html)")
        }
        var inverse = StyledCell(text: "y")
        inverse.inverse = true
        let swapped = render([[inverse]])
        XCTAssertTrue(swapped.contains("color:#111111;background-color:#cccccc;"), swapped)
    }

    func testTextIsEscapedAndLinesTrimmed() {
        let html = render([cells("<a & \"b\">   "), cells("next")])
        XCTAssertTrue(html.contains("&lt;a &amp; &quot;b&quot;&gt;\nnext"), html)
    }

    func testTheLengthLimit() {
        XCTAssertTrue(TerminalHTML.shouldInclude(textLength: 100))
        XCTAssertFalse(TerminalHTML.shouldInclude(textLength: 32 * 1024), "Tabby: below 32 KiB only")
    }

    // MARK: Word separators

    func word(_ line: String, at col: Int, _ separators: String = TerminalTextDefaults.wordSeparator) -> String {
        let chars = line.map { Optional($0) }
        guard let range = WordSelection.range(in: chars, at: col, separators: separators) else { return "" }
        return String(line.map { $0 }[range])
    }

    func testDoubleClickStopsAtTheSeparators() {
        let line = "ls /usr/local/bin:x (y) 'q'"
        XCTAssertEqual(word(line, at: 5), "/usr/local/bin:x", "/ and : are not separators by default")
        XCTAssertEqual(word(line, at: 21), "y")
        XCTAssertEqual(word(line, at: 25), "q")
        XCTAssertEqual(word(line, at: 20), "(", "a separator selects itself")
        XCTAssertEqual(word(line, at: 5, " /"), "usr")
        XCTAssertEqual(word("a   b", at: 2), "   ", "a space selects the run of spaces")
        XCTAssertEqual(word("ab", at: 5), "", "past the end: nothing")
    }

    func testAWideCharacterBelongsToItsWord() {
        // "日" takes two cells; the second is nil.
        let chars: [Character?] = ["a", "日", nil, "b", " ", "c"]
        XCTAssertEqual(WordSelection.range(in: chars, at: 2, separators: " "), 0...3)
    }

    // MARK: OSC 1337 and dropped files

    func testTheCurrentDirectoryOfOSC1337() {
        XCTAssertEqual(TerminalOSC.iTermCurrentDirectory("CurrentDir=/tmp/a=b"), "/tmp/a=b", "the whole value (Tabby cuts at a second =)")
        XCTAssertEqual(TerminalOSC.iTermCurrentDirectory("CurrentDir=~/src"), "~/src")
        XCTAssertNil(TerminalOSC.iTermCurrentDirectory("SetUserVar=x=eQ=="))
        XCTAssertNil(TerminalOSC.iTermCurrentDirectory("CurrentDir="))
        XCTAssertNil(TerminalOSC.iTermCurrentDirectory("ShellIntegrationVersion"))
    }

    func testDroppedPathsAreQuotedOneByOne() {
        XCTAssertEqual(PathDrop.text(for: ["/tmp/a b", "/x/it's"], bracketed: false), ["'/tmp/a b' ", "'/x/it'\\''s' "])
        XCTAssertEqual(PathDrop.text(for: ["/a\u{1b}[31m\nb"], bracketed: false), ["'/a[31mb' "], "control characters go")
        XCTAssertEqual(PathDrop.text(for: ["/a"], bracketed: true), ["\u{1b}[200~'/a' \u{1b}[201~"])
    }
}
