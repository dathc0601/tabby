import XCTest
@testable import TabbyCore
@testable import TabbyTerminal

/// Phase 6: the pane's ZMODEM bridge (Tabby's `ZModemMiddleware`), against a remote played by
/// TabbyCore's own sender (`sz`) or receiver (`rz`).
final class ZModemBridgeTests: XCTestCase {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    final class MemorySink: ZModemFileSink {
        var data: [UInt8] = []
        var outcome: ZModemOutcome?
        var progressed: UInt64 = 0
        var isCancelled = false
        var cancelAfter: Int?
        func write(_ bytes: [UInt8]) throws {
            data += bytes
            if let cancelAfter, data.count >= cancelAfter { isCancelled = true }
        }
        func progress(_ bytes: UInt64) { progressed = bytes }
        func finish(_ outcome: ZModemOutcome) { self.outcome = outcome }
    }

    final class Handle: ZModemTransferHandle {
        var outcome: ZModemOutcome?
        var progressed: UInt64 = 0
        var isCancelled = false
        func progress(_ bytes: UInt64) { progressed = bytes }
        func finish(_ outcome: ZModemOutcome) { self.outcome = outcome }
    }

    /// A bridge wired to a queue: everything runs in order when `run()` is called.
    final class Harness {
        var queue: [() -> Void] = []
        var terminal: [UInt8] = []
        var lines: [UInt8] = []
        var asked: [ZModemDirection] = []
        var answer = true
        var sinks: [String: MemorySink] = [:]
        var uploads: [ZModemUpload] = []
        let bridge = ZModemBridge()
        var remoteIn: ([UInt8]) -> Void = { _ in }

        init() {
            bridge.toRemote = { [unowned self] b in queue.append { self.remoteIn(b) } }
            bridge.toTerminal = { [unowned self] in terminal += $0 }
            bridge.showLine = { [unowned self] in lines += Array($0.utf8); terminal += Array($0.utf8) }
            bridge.ask = { [unowned self] direction, answer in asked.append(direction); answer(self.answer) }
            bridge.save = { [unowned self] info, answer in
                let sink = MemorySink()
                sinks[info.name] = sink
                answer(sink)
            }
            bridge.chooseFiles = { [unowned self] answer in answer(uploads) }
            bridge.schedule = { [unowned self] in queue.append($0) }
            bridge.after = { _, work in }
        }

        func run() {
            var steps = 0
            while !queue.isEmpty, steps < 100_000 {
                queue.removeFirst()()
                steps += 1
            }
        }

        var text: String { String(decoding: lines, as: UTF8.self) }
    }

    func outgoing(_ files: [(String, [UInt8])]) -> [ZModemOutgoingFile] {
        files.map { name, data in
            ZModemOutgoingFile(info: ZModemFileInfo(name: name, size: UInt64(data.count), mtime: nil, mode: 0o644)) { o, n in
                Array(data[Int(o)..<min(data.count, Int(o) + n)])
            }
        }
    }

    /// The remote runs `sz` for `files`, then prints a prompt.
    func remoteSz(_ h: Harness, _ files: [(String, [UInt8])]) -> ZModemSender {
        let sz = ZModemSender(files: outgoing(files))
        sz.schedule = { work in h.queue.append(work) }
        sz.toRemote = { b in h.queue.append { h.bridge.fromRemote(b) } }
        sz.onFinished = { _ in h.queue.append { h.bridge.fromRemote(self.bytes("$ ")) } }
        h.remoteIn = { sz.feed($0) }
        h.bridge.fromRemote(bytes("sz files\r\nrz\r") + ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit)))
        return sz
    }

    func testTextGoesStraightThrough() {
        let h = Harness()
        h.bridge.fromRemote(bytes("hello *world*\r\n"))
        XCTAssertEqual(h.terminal, bytes("hello *world*\r\n"))
        XCTAssertEqual(h.asked, [])
    }

    func testReceivingAsksAndSavesEachFile() {
        let h = Harness()
        let big = (0..<70_000).map { UInt8($0 % 241) }
        _ = remoteSz(h, [("notes.txt", bytes("hello")), ("big.bin", big)])
        h.run()
        XCTAssertEqual(h.asked, [.receive])
        XCTAssertEqual(h.sinks["notes.txt"]?.data, bytes("hello"))
        XCTAssertEqual(h.sinks["big.bin"]?.data, big)
        XCTAssertEqual(h.sinks["big.bin"]?.outcome, .done)
        XCTAssertEqual(h.sinks["big.bin"]?.progressed, UInt64(big.count))
        let text = h.text
        for part in [" ZMODEM ", "Session started", "------------------------", " Offered ", "notes.txt", " Received ", " Complete "] {
            XCTAssertTrue(text.contains(part), "\(part) in \(text.debugDescription)")
        }
        let terminal = String(decoding: h.terminal, as: UTF8.self)
        XCTAssertTrue(terminal.hasPrefix("sz files\r\nrz\r"), "text before the header")
        XCTAssertTrue(terminal.hasSuffix("$ "), "the prompt after the session: \(terminal.suffix(40).debugDescription)")
        XCTAssertFalse(terminal.contains("**\u{18}B"), "no protocol bytes on screen")
    }

    func testRejectingAbortsTheRemote() {
        let h = Harness()
        h.answer = false
        var remoteError: String?
        let sz = remoteSz(h, [("x", bytes("x"))])
        sz.onError = { remoteError = $0 }
        h.run()
        XCTAssertTrue(h.sinks.isEmpty)
        XCTAssertNotNil(remoteError, "sz was told")
        XCTAssertTrue(h.text.contains(" Rejected "), h.text)
    }

    func testCancellingAFileInTheTransfersListSkipsIt() {
        let h = Harness()
        let big = (0..<60_000).map { UInt8($0 % 5) }
        var done: [Int: Bool] = [:]
        let sz = remoteSz(h, [("big.bin", big), ("small", bytes("ok"))])
        sz.onFileDone = { done[$0] = $1 }
        h.bridge.save = { info, answer in
            let sink = MemorySink()
            if info.name == "big.bin" { sink.cancelAfter = 3000 }
            h.sinks[info.name] = sink
            answer(sink)
        }
        h.run()
        XCTAssertEqual(h.sinks["big.bin"]?.outcome, .cancelled)
        XCTAssertLessThan(h.sinks["big.bin"]?.data.count ?? 0, big.count)
        XCTAssertEqual(h.sinks["small"]?.data, bytes("ok"))
        XCTAssertEqual(done[0], true)
        XCTAssertTrue(h.text.contains(" Canceled "), h.text)
    }

    func testCtrlCCancelsTheFileBeingReceived() {
        let h = Harness()
        let big = (0..<60_000).map { UInt8($0 % 3) }
        _ = remoteSz(h, [("big.bin", big)])
        h.bridge.save = { info, answer in
            let sink = MemorySink()
            h.sinks[info.name] = sink
            answer(sink)
            h.queue.append { h.bridge.userInput([0x03]) }
        }
        h.run()
        XCTAssertEqual(h.sinks["big.bin"]?.outcome, .cancelled)
        XCTAssertTrue(h.text.contains(" Canceled "))
    }

    func testSendingPicksFilesAndUploadsThem() {
        let h = Harness()
        let data = (0..<50_000).map { UInt8($0 % 199) }
        let handle = Handle()
        h.uploads = outgoing([("up.bin", data)]).map { ZModemUpload(file: $0, handle: handle) }
        let rz = ZModemReceiver()
        var got: [UInt8] = []
        rz.toRemote = { b in h.queue.append { h.bridge.fromRemote(b) } }
        rz.onOffer = { _ in rz.accept() }
        rz.onData = { got += $0 }
        rz.onFinished = { _ in h.queue.append { h.bridge.fromRemote(self.bytes("$ ")) } }
        h.remoteIn = { rz.feed($0) }
        h.bridge.fromRemote(bytes("rz waiting to receive."))
        rz.start()
        h.run()
        XCTAssertEqual(h.asked, [.send])
        XCTAssertEqual(got, data)
        XCTAssertEqual(handle.outcome, .done)
        XCTAssertEqual(handle.progressed, UInt64(data.count))
        XCTAssertTrue(h.text.contains(" Sent "), h.text)
        XCTAssertTrue(h.text.contains(" Complete "))
        XCTAssertTrue(String(decoding: h.terminal, as: UTF8.self).hasSuffix("$ "))
    }

    func testChoosingNothingEndsTheSession() {
        let h = Harness()
        let rz = ZModemReceiver()
        var ended = false
        rz.toRemote = { b in h.queue.append { h.bridge.fromRemote(b) } }
        rz.onFinished = { _ in ended = true }
        h.remoteIn = { rz.feed($0) }
        rz.start()
        h.run()
        XCTAssertTrue(ended)
        XCTAssertTrue(h.text.contains(" Complete "))
    }

    func testAStalledHeaderStartIsShownAfterAPause() {
        let h = Harness()
        var later: [() -> Void] = []
        h.bridge.after = { _, work in later.append(work) }
        h.bridge.fromRemote(bytes("progress **"))
        XCTAssertEqual(h.terminal, bytes("progress "))
        later.forEach { $0() }
        XCTAssertEqual(h.terminal, bytes("progress **"))
    }
}
