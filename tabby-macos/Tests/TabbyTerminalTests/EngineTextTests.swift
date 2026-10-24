#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 6 on the real SwiftTerm view: formatted copy, word separators, the buffer for
/// "Export to file". A private pasteboard keeps the user's clipboard out of it.
final class EngineTextTests: XCTestCase {
    func engine(_ user: [String: ConfigValue] = [:]) throws -> (SwiftTermEngine, NSPasteboard) {
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: .object(["terminal": .object(user)]))
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

    func testTheBufferTextIncludesTheScrollback() throws {
        let (engine, _) = try engine()
        engine.feed(Data((1...60).map { "line \($0)" }.joined(separator: "\r\n").utf8))
        let text = engine.bufferText()
        XCTAssertTrue(text.hasPrefix("line 1\n"), String(text.prefix(40)))
        XCTAssertTrue(text.contains("line 60"))
    }
}
#endif
