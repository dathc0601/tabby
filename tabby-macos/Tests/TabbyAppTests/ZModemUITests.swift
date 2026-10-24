#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyTerminal
@testable import TabbyApp

/// Phase 6: the window's part of ZMODEM (Tabby's `zmodem.ts` UI): the question, save and open
/// panels (answered here), files on disk and rows in the transfers list.
@MainActor
final class ZModemUITests: XCTestCase {
    var folder: URL!

    override func setUp() {
        super.setUp()
        TestApp.boot()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("tabbymac-zmodem-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        MainWindowController.zmodemAsk = { _, _, answer in answer(true) }
    }

    override func tearDown() {
        MainWindowController.zmodemAsk = MainWindowController.defaultZModemAsk
        MainWindowController.zmodemSavePanel = MainWindowController.defaultZModemSavePanel
        MainWindowController.zmodemOpenPanel = MainWindowController.defaultZModemOpenPanel
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func window() throws -> (MainWindowController, TerminalPane) {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        let pane = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("remote", "sleep 30"))?.focusedPane)
        TestApp.pump(until: { pane.isRunning })
        return (c, pane)
    }

    /// The remote end runs `sz` for `files` through the pane's bridge.
    func remoteSz(_ pane: TerminalPane, _ files: [(String, [UInt8])]) -> ZModemSender {
        let sz = ZModemSender(files: files.map { name, data in
            ZModemOutgoingFile(info: ZModemFileInfo(name: name, size: UInt64(data.count), mtime: nil, mode: 0o600)) { o, n in
                Array(data[Int(o)..<min(data.count, Int(o) + n)])
            }
        })
        sz.toRemote = { [weak pane] bytes in DispatchQueue.main.async { pane?.zmodem.fromRemote(bytes) } }
        pane.zmodem.toRemote = { bytes in DispatchQueue.main.async { sz.feed(bytes) } }
        pane.zmodem.fromRemote(ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit)))
        return sz
    }

    func testTheQuestionUsesTabbysWords() {
        XCTAssertEqual(ZModemUI.question.title, "Accept a ZMODEM session?")
        XCTAssertEqual(ZModemUI.question.message, "If you have not requested it, it could be a sign of malicious activity.")
        XCTAssertEqual(ZModemUI.question.accept, "Accept")
        XCTAssertEqual(ZModemUI.question.reject, "Reject")
    }

    func testAReceivedFileLandsWhereChosen() throws {
        let (c, pane) = try window()
        defer { TestApp.dispose(c) }
        let target = folder.appendingPathComponent("saved.txt")
        var suggested: String?
        MainWindowController.zmodemSavePanel = { _, name, done in suggested = name; done(target) }
        var ended = false
        let sz = remoteSz(pane, [("hello.txt", Array("hello zmodem".utf8))])
        sz.onFinished = { _ in ended = true }
        XCTAssertTrue(TestApp.pump(until: { ended }))
        XCTAssertEqual(suggested, "hello.txt")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "hello zmodem")
        let mode = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644, "Tabby writes 0644")
        let row = try XCTUnwrap(TransferCenter.shared.transfers.last)
        XCTAssertEqual(row.name, "hello.txt")
        XCTAssertEqual(row.direction, .download)
        XCTAssertEqual(row.status, .done)
        XCTAssertEqual(row.localURL, target)
    }

    func testCancellingTheRowStopsTheFileAndRemovesIt() throws {
        let (c, pane) = try window()
        defer { TestApp.dispose(c) }
        let target = folder.appendingPathComponent("big.bin")
        MainWindowController.zmodemSavePanel = { _, _, done in done(target) }
        var ended = false
        let big = (0..<400_000).map { UInt8($0 % 3) }
        let sz = remoteSz(pane, [("big.bin", big)])
        sz.onFinished = { _ in ended = true }
        sz.onError = { _ in ended = true }
        XCTAssertTrue(TestApp.pump(until: { TransferCenter.shared.transfers.last?.name == "big.bin" }))
        let row = try XCTUnwrap(TransferCenter.shared.transfers.last)
        row.cancel()
        XCTAssertTrue(TestApp.pump(until: { ended }))
        XCTAssertEqual(row.status, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "no half file is left")
    }

    func testChosenFilesAreSent() throws {
        let (c, pane) = try window()
        defer { TestApp.dispose(c) }
        let source = folder.appendingPathComponent("up load.bin")
        let data = Data((0..<90_000).map { UInt8($0 % 101) })
        try data.write(to: source)
        MainWindowController.zmodemOpenPanel = { _, done in done([source]) }
        let rz = ZModemReceiver()
        var got = Data()
        var offered: ZModemFileInfo?
        var ended = false
        rz.toRemote = { [weak pane] bytes in DispatchQueue.main.async { pane?.zmodem.fromRemote(bytes) } }
        pane.zmodem.toRemote = { bytes in DispatchQueue.main.async { rz.feed(bytes) } }
        rz.onOffer = { offered = $0; rz.accept() }
        rz.onData = { got.append(contentsOf: $0) }
        rz.onFinished = { _ in ended = true }
        rz.start()
        XCTAssertTrue(TestApp.pump(until: { ended }))
        XCTAssertEqual(offered?.name, "up load.bin")
        XCTAssertEqual(offered?.size, UInt64(data.count))
        XCTAssertEqual(got, data)
        let row = try XCTUnwrap(TransferCenter.shared.transfers.last)
        XCTAssertEqual(row.direction, .upload)
        XCTAssertEqual(row.status, .done)
    }

    /// Review: the question switched to the asking pane's tab, so any host could pull the
    /// user away from what they were typing. It now names the tab and leaves it where it is.
    func testTheQuestionNamesTheTabAndDoesntSwitchToIt() throws {
        let (c, pane) = try window()
        defer { TestApp.dispose(c) }
        let other = try XCTUnwrap(c.model.openTab(profile: TestApp.profile("busy here", "sleep 30")))
        XCTAssertEqual(c.model.activeTab?.id, other.id)
        var asked: String?
        MainWindowController.zmodemAsk = { _, title, answer in asked = title; answer(false) }
        pane.zmodem.toRemote = { _ in }
        pane.zmodem.fromRemote(ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit)))
        XCTAssertEqual(asked, pane.title)
        XCTAssertEqual(c.model.activeTab?.id, other.id, "the tab in front stays")
        XCTAssertTrue(ZModemUI.message(for: "remote").contains("remote"))
    }
}
#endif
