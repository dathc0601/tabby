#if canImport(AppKit)
import XCTest
import AppKit
import SwiftTerm
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 6 on the real SwiftTerm view: formatted copy, word separators, the buffer for
/// "Export to file". A private pasteboard keeps the user's clipboard out of it.
final class EngineTextTests: XCTestCase {
    func engine(_ user: [String: ConfigValue] = [:], clickableLinks: String? = nil) throws -> (SwiftTermEngine, NSPasteboard) {
        var root: [String: ConfigValue] = ["terminal": .object(user)]
        if let clickableLinks { root["clickableLinks"] = .object(["modifier": .string(clickableLinks)]) }
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: .object(root))
        let settings = TerminalSettings(config: config)
        let engine = SwiftTermEngine(frame: CGRect(x: 0, y: 0, width: 600, height: 200), settings: settings)
        engine.apply(settings: settings, scheme: .tabbyDefault, fontSize: settings.fontSize)
        let board = NSPasteboard(name: NSPasteboard.Name("tabbymac-test-\(UUID().uuidString)"))
        engine.pasteboard = board
        addTeardownBlock { board.releaseGlobally() }
        return (engine, board)
    }

    func testCopyAddsHTMLWithTheColours() throws {
        let (engine, board) = try engine()
        engine.feed(Data("\u{1b}[31mred\u{1b}[0m plain".utf8))
        engine.selectAll()
        XCTAssertTrue(engine.copySelection())
        XCTAssertEqual(board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "red plain")
        let html = try XCTUnwrap(board.string(forType: .html), "copyAsHTML is on by default")
        let red = ColorScheme.tabbyDefault.paletteRGB[1].hex
        XCTAssertTrue(html.contains("<span style=\"color:\(red);\">red</span>"), html)
        XCTAssertTrue(html.contains(" plain"), html)
    }

    func testCopyWithoutFormattingIsPlainText() throws {
        let (engine, board) = try engine(["copyAsHTML": false])
        engine.feed(Data("\u{1b}[31mred\u{1b}[0m".utf8))
        engine.selectAll()
        XCTAssertTrue(engine.copySelection())
        XCTAssertEqual(board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "red")
        XCTAssertNil(board.string(forType: .html))
    }

    func testDoubleClickStopsAtTheWordSeparators() throws {
        let (engine, _) = try engine()
        engine.feed(Data("ls /usr/local/bin:x (y)".utf8))
        engine.selectWord(column: 5, row: 0)
        XCTAssertEqual(engine.selectedText(), "/usr/local/bin:x")
        engine.selectWord(column: 21, row: 0)
        XCTAssertEqual(engine.selectedText(), "y")
        let (other, _) = try self.engine(["wordSeparator": " /"])
        other.feed(Data("ls /usr/local/bin:x".utf8))
        other.selectWord(column: 5, row: 0)
        XCTAssertEqual(other.selectedText(), "usr")
    }

    final class DirectorySpy: TerminalEngineDelegate {
        var directories: [String] = []
        func engine(_ engine: TerminalEngine, send data: Data) {}
        func engine(_ engine: TerminalEngine, resized cols: Int, rows: Int) {}
        func engine(_ engine: TerminalEngine, titleChanged title: String) {}
        func engine(_ engine: TerminalEngine, directoryChanged directory: String?) { directory.map { directories.append($0) } }
        func engineBell(_ engine: TerminalEngine) {}
        func engineDidFocus(_ engine: TerminalEngine) {}
        func engine(_ engine: TerminalEngine, paste text: String) {}
        func engineSelectionChanged(_ engine: TerminalEngine) {}
    }

    func testOSC1337CurrentDirReportsTheDirectory() throws {
        let (engine, _) = try engine()
        let spy = DirectorySpy()
        engine.engineDelegate = spy
        engine.feed(Data("\u{1b}]1337;CurrentDir=/tmp/a=b\u{07}".utf8))
        engine.feed(Data("\u{1b}]1337;SetUserVar=x=eQ==\u{07}".utf8))
        XCTAssertEqual(spy.directories, ["/tmp/a=b"])
    }

    func testAHomeRelativeDirectoryIsExpandedForLocalPanesOnly() throws {
        let (local, localEngine, _) = try makeFakePane(type: "local")
        local.engine(localEngine, directoryChanged: "~/src")
        XCTAssertEqual(local.currentDirectory(), NSHomeDirectory() + "/src")
        let (ssh, sshEngine, _) = try makeFakePane(type: "ssh")
        ssh.engine(sshEngine, directoryChanged: "~/src")
        XCTAssertEqual(ssh.currentDirectory(), "~/src", "the remote home is unknown here")
    }

    final class LinkSpy: TerminalEngineDelegate {
        var links: [String] = []
        func engine(_ engine: TerminalEngine, send data: Data) {}
        func engine(_ engine: TerminalEngine, resized cols: Int, rows: Int) {}
        func engine(_ engine: TerminalEngine, titleChanged title: String) {}
        func engine(_ engine: TerminalEngine, directoryChanged directory: String?) {}
        func engineBell(_ engine: TerminalEngine) {}
        func engineDidFocus(_ engine: TerminalEngine) {}
        func engine(_ engine: TerminalEngine, paste text: String) {}
        func engineSelectionChanged(_ engine: TerminalEngine) {}
        func engine(_ engine: TerminalEngine, openLink link: String) { links.append(link) }
    }

    func testTheLinkSettingPicksHowSwiftTermReportsLinks() throws {
        let (plain, _) = try engine()
        XCTAssertEqual(plain.linkReporting, .implicit)
        XCTAssertEqual(plain.linkHighlightMode, .hover, "Tabby's default: a plain click opens a link")
        let (command, _) = try engine(clickableLinks: "metaKey")
        XCTAssertEqual(command.linkHighlightMode, .hoverWithModifier)
        let (shift, _) = try engine(clickableLinks: "shiftKey")
        XCTAssertEqual(shift.linkReporting, LinkReporting.none, "⇧ and ⌥ clicks are handled by TabbyMac")
    }

    func testAClickOpensTheLinkUnderItWithTheRightKey() throws {
        let (plain, _) = try engine()
        let spy = LinkSpy()
        plain.engineDelegate = spy
        plain.feed(Data("ping 192.168.1.10 or https://example.com/x".utf8))
        plain.clickLink(column: 8, row: 0, modifiers: [])
        XCTAssertEqual(spy.links, ["192.168.1.10"], "SwiftTerm doesn't detect bare addresses; TabbyMac does")
        let (shift, _) = try engine(clickableLinks: "shiftKey")
        let shiftSpy = LinkSpy()
        shift.engineDelegate = shiftSpy
        shift.feed(Data("see https://example.com/x now".utf8))
        shift.clickLink(column: 8, row: 0, modifiers: [])
        XCTAssertEqual(shiftSpy.links, [], "the key is required")
        shift.clickLink(column: 8, row: 0, modifiers: [.shift])
        XCTAssertEqual(shiftSpy.links, ["https://example.com/x"])
    }

    /// M11 walk: a plain click on `telnet://127.0.0.1:2323` did nothing. SwiftTerm doesn't know
    /// the scheme and reported the rest as the path `//127.0.0.1:2323`.
    func testATelnetLinkIsNotTakenForAPath() throws {
        let (plain, _) = try engine()
        let spy = LinkSpy()
        plain.engineDelegate = spy
        plain.feed(Data("telnet://127.0.0.1:2323".utf8))
        plain.clickedCell = (3, 0)
        plain.requestOpenLink(source: plain, link: "//127.0.0.1:2323", params: [:])
        XCTAssertEqual(spy.links, ["telnet://127.0.0.1:2323"])
        let (shift, _) = try engine(clickableLinks: "shiftKey")
        let shiftSpy = LinkSpy()
        shift.engineDelegate = shiftSpy
        shift.feed(Data("telnet://127.0.0.1:2323".utf8))
        shift.clickLink(column: 3, row: 0, modifiers: [.shift])
        XCTAssertEqual(shiftSpy.links, ["telnet://127.0.0.1:2323"], "SwiftTerm's own lookup (⇧ mode) too")
    }

    final class ReplySpy: TerminalEngineDelegate {
        var sent = Data()
        func engine(_ engine: TerminalEngine, send data: Data) { sent.append(data) }
        func engine(_ engine: TerminalEngine, resized cols: Int, rows: Int) {}
        func engine(_ engine: TerminalEngine, titleChanged title: String) {}
        func engine(_ engine: TerminalEngine, directoryChanged directory: String?) {}
        func engineBell(_ engine: TerminalEngine) {}
        func engineDidFocus(_ engine: TerminalEngine) {}
        func engine(_ engine: TerminalEngine, paste text: String) {}
        func engineSelectionChanged(_ engine: TerminalEngine) {}
    }

    /// Tabby's `terminal.sixel`: SwiftTerm 1.20 always draws sixel images, so the switch decides
    /// whether the terminal tells programs it can (the ";4" of its device attributes).
    func testTheSixelSettingDecidesWhatTheTerminalAdvertises() throws {
        for (setting, advertised) in [(true, true), (false, false)] {
            let (engine, _) = try engine(["sixel": .bool(setting)])
            let spy = ReplySpy()
            engine.engineDelegate = spy
            engine.feed(Data("\u{1b}[c".utf8))
            let reply = String(decoding: spy.sent, as: UTF8.self)
            XCTAssertTrue(reply.hasPrefix("\u{1b}[?"), reply.debugDescription)
            XCTAssertEqual(reply.contains(";4"), advertised, "sixel \(setting): \(reply.debugDescription)")
        }
    }

    func testTheBufferTextIncludesTheScrollback() throws {
        let (engine, _) = try engine()
        engine.feed(Data((1...60).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        let text = engine.bufferText()
        XCTAssertTrue(text.hasPrefix("line 1\n"), String(text.prefix(40)))
        XCTAssertTrue(text.contains("line 60"))
    }
}
#endif
