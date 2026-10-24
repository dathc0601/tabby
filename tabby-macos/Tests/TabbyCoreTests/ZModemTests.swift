import XCTest
@testable import TabbyCore

/// Phase 6: ZMODEM (Tabby's `zmodem.ts` over zmodem.js), implemented in TabbyCore and checked
/// against itself here and against lrzsz in ZModemInteropTests.
final class ZModemTests: XCTestCase {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    // MARK: Building blocks

    func testCRCs() {
        XCTAssertEqual(ZModemCRC.crc16(bytes("123456789")), 0x31C3, "CRC-16/XMODEM")
        XCTAssertEqual(ZModemCRC.crc32(bytes("123456789")), 0xCBF4_3926, "CRC-32")
    }

    func testAHexHeaderIsWhatRzSends() {
        let header = ZModemHeader(type: .rinit, flags: ZModem.canfdx | ZModem.canovio | ZModem.canfc32)
        XCTAssertEqual(ZModemEncoder().hexHeader(header), bytes("**\u{18}B0100000023be50\r") + [0x8A, 0x11],
                       "lrzsz's `rz waiting to receive.` header")
        let fin = ZModemEncoder().hexHeader(ZModemHeader(type: .fin))
        XCTAssertEqual(Array(fin.suffix(2)), [0x0D, 0x8A])
        XCTAssertFalse(fin.contains(0x11), "no XON after ZFIN")
    }

    func testEscaping() {
        var encoder = ZModemEncoder()
        XCTAssertEqual(encoder.escape([0x18, 0x11, 0x13, 0x10, 0x90, 0x91, 0x93, 0x41]),
                       [0x18, 0x58, 0x18, 0x51, 0x18, 0x53, 0x18, 0x50, 0x18, 0xD0, 0x18, 0xD1, 0x18, 0xD3, 0x41])
        var telenet = ZModemEncoder()
        XCTAssertEqual(telenet.escape(bytes("@\r")), [0x40, 0x18, 0x4D], "CR after @ (lrzsz)")
        XCTAssertEqual(telenet.escape(bytes("a\r")), bytes("a\r"))
    }

    func testFramesSurviveTheRoundTrip() {
        var encoder = ZModemEncoder()
        let payload = (0..<600).map { UInt8($0 % 256) }
        var stream: [UInt8] = bytes("noise")
        stream += encoder.hexHeader(ZModemHeader(type: .rpos, position: 1234))
        stream += encoder.binaryHeader(ZModemHeader(type: .data, position: 77), crc32: true)
        stream += encoder.subpacket(payload, end: ZModem.crcg, crc32: true)
        stream += encoder.subpacket([1, 2, 3], end: ZModem.crce, crc32: true)
        stream += encoder.binaryHeader(ZModemHeader(type: .file), crc32: false)
        stream += encoder.subpacket(bytes("a\0"), end: ZModem.crcw, crc32: false)
        var decoder = ZModemDecoder()
        // One byte at a time: the decoder keeps its place across chunks.
        let events = stream.flatMap { decoder.feed([$0]) }
        XCTAssertEqual(events, [
            .header(ZModemHeader(type: .rpos, position: 1234)),
            .header(ZModemHeader(type: .data, position: 77)),
            .data(payload, end: ZModem.crcg),
            .data([1, 2, 3], end: ZModem.crce),
            .header(ZModemHeader(type: .file)),
            .data(bytes("a\0"), end: ZModem.crcw),
        ])
    }

    func testACorruptSubpacketIsReported() {
        var encoder = ZModemEncoder()
        var stream = encoder.binaryHeader(ZModemHeader(type: .data, position: 0), crc32: true)
        var packet = encoder.subpacket(bytes("hello world"), end: ZModem.crcg, crc32: true)
        packet[3] ^= 0x01
        stream += packet
        stream += encoder.binaryHeader(ZModemHeader(type: .data, position: 0), crc32: true)
        var decoder = ZModemDecoder()
        let events = decoder.feed(stream)
        XCTAssertEqual(events.first, .header(ZModemHeader(type: .data, position: 0)))
        XCTAssertTrue(events.contains(.badCRC))
        XCTAssertEqual(events.last, .header(ZModemHeader(type: .data, position: 0)), "back in sync at the next header")
    }

    func testFiveCancelsEndTheSession() {
        var decoder = ZModemDecoder()
        XCTAssertEqual(decoder.feed(ZModem.abortSequence), [.cancelled])
    }

    func testTheFileOffer() throws {
        let info = try XCTUnwrap(ZModemFileInfo(subpacket: bytes("dir/report final.pdf\u{0}1234 14672751413 100644 0 2 2048\u{0}")))
        XCTAssertEqual(info.name, "report final.pdf", "no folders from the remote")
        XCTAssertEqual(info.size, 1234)
        XCTAssertEqual(info.mode, 0o100644)
        XCTAssertEqual(info.mtime, Date(timeIntervalSince1970: 0o14672751413))
        XCTAssertEqual(ZModemFileInfo(name: "a b.txt", size: 5, mtime: Date(timeIntervalSince1970: 8), mode: 0o644).subpacket,
                       bytes("a b.txt\u{0}5 10 644 0 1 5\u{0}"))
        XCTAssertNil(ZModemFileInfo(subpacket: bytes("\u{0}12\u{0}")), "no name")
        XCTAssertEqual(ZModemFileInfo(subpacket: bytes("../../.ssh/authorized_keys\u{0}1\u{0}"))?.name, "authorized_keys")
    }

    // MARK: Detection

    func testTheSentryPassesTextAndSpotsAHeader() {
        let sentry = ZModemSentry()
        var r = sentry.feed(bytes("hello *world* "))
        XCTAssertEqual(r.toTerminal, bytes("hello *world* "))
        XCTAssertNil(r.detection)
        let rqinit = ZModemEncoder().hexHeader(ZModemHeader(type: .rqinit))
        r = sentry.feed(bytes("rz\r") + Array(rqinit.prefix(8)))
        XCTAssertEqual(r.toTerminal, bytes("rz\r"), "a header start is held")
        r = sentry.feed(Array(rqinit.dropFirst(8)) + [0x41])
        XCTAssertEqual(r.detection, .receive)
        XCTAssertEqual(r.protocolBytes, rqinit + [0x41], "the header and what follows go to the protocol")
        XCTAssertEqual(r.toTerminal, [])
    }

    func testTheSentrySpotsAReceiverAndLetsBadHeadersThrough() {
        let sentry = ZModemSentry()
        let rinit = ZModemEncoder().hexHeader(ZModemHeader(type: .rinit, flags: 0x23))
        XCTAssertEqual(sentry.feed(bytes("rz waiting to receive.") + rinit).detection, .send)
        let other = ZModemSentry()
        var fake = rinit
        fake[12] = UInt8(ascii: "f")
        let r = other.feed(fake + bytes("x"))
        XCTAssertNil(r.detection, "a bad CRC is text")
        XCTAssertEqual(r.toTerminal, fake + bytes("x"))
        let held = ZModemSentry()
        XCTAssertEqual(held.feed(bytes("**")).toTerminal, [])
        XCTAssertEqual(held.flush(), bytes("**"), "a stalled start is let through")
    }

    // MARK: Sessions

    /// Sender and receiver wired to each other; returns the files received.
    func transfer(_ files: [(String, [UInt8])], skip: Set<String> = [], corrupt: ((inout [UInt8]) -> Void)? = nil,
                  cancelAfter: Int? = nil) -> (received: [String: [UInt8]], senderDone: [Int: Bool], receiverEnded: Bool,
                                               senderEnded: Bool, errors: [String], trailing: [UInt8]) {
        var queue: [() -> Void] = []
        var received: [String: [UInt8]] = [:]
        var current: String?
        var senderDone: [Int: Bool] = [:]
        var receiverEnded = false, senderEnded = false
        var errors: [String] = []
        var trailing: [UInt8] = []
        var corrupted = false
        var receivedBytes = 0

        let outgoing = files.map { name, data in
            ZModemOutgoingFile(info: ZModemFileInfo(name: name, size: UInt64(data.count), mtime: nil, mode: 0o644)) { offset, count in
                Array(data[Int(offset)..<min(data.count, Int(offset) + count)])
            }
        }
        let sender = ZModemSender(files: outgoing)
        let receiver = ZModemReceiver()
        sender.schedule = { queue.append($0) }
        receiver.toRemote = { bytes in queue.append { sender.feed(bytes) } }
        sender.toRemote = { bytes in
            var b = bytes
            if let corrupt, !corrupted, b.count > 900 { corrupt(&b); corrupted = true }
            queue.append { receiver.feed(b) }
        }
        receiver.onOffer = { info in
            if skip.contains(info.name) { receiver.skip() } else { current = info.name; received[info.name] = []; receiver.accept() }
        }
        receiver.onData = { data in
            received[current!]! += data
            receivedBytes += data.count
            if let cancelAfter, receivedBytes >= cancelAfter { receiver.cancel() }
        }
        receiver.onFinished = { rest in receiverEnded = true; trailing = rest }
        receiver.onError = { errors.append("receiver: \($0)") }
        sender.onFileDone = { index, skipped in senderDone[index] = skipped }
        sender.onFinished = { _ in senderEnded = true }
        sender.onError = { errors.append("sender: \($0)") }

        receiver.start()
        // The sender starts on the receiver's ZRINIT (as the sentry would hand it over).
        var steps = 0
        while !queue.isEmpty, steps < 200_000 {
            queue.removeFirst()()
            steps += 1
        }
        return (received, senderDone, receiverEnded, senderEnded, errors, trailing)
    }

    func testFilesGoAcross() {
        let big = (0..<300_000).map { _ in UInt8.random(in: 0...255) }
        let r = transfer([("empty", []), ("hello.txt", bytes("hello")), ("big.bin", big), ("with spaces.txt", bytes("x y"))])
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.received["empty"], [])
        XCTAssertEqual(r.received["hello.txt"], bytes("hello"))
        XCTAssertEqual(r.received["big.bin"], big)
        XCTAssertEqual(r.received["with spaces.txt"], bytes("x y"))
        XCTAssertEqual(r.senderDone, [0: false, 1: false, 2: false, 3: false])
        XCTAssertTrue(r.receiverEnded)
        XCTAssertTrue(r.senderEnded)
    }

    func testASkippedFileIsLeftOut() {
        let r = transfer([("a", bytes("aaa")), ("b", bytes("bbb")), ("c", bytes("ccc"))], skip: ["b"])
        XCTAssertEqual(r.received.keys.sorted(), ["a", "c"])
        XCTAssertEqual(r.senderDone, [0: false, 1: true, 2: false])
        XCTAssertTrue(r.receiverEnded)
    }

    func testACorruptedSubpacketIsSentAgain() {
        let data = (0..<20_000).map { UInt8($0 % 251) }
        let r = transfer([("data", data)]) { packet in packet[packet.count / 2] ^= 0x55 }
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(r.received["data"], data, "ZRPOS sent the rest again")
    }

    func testCancellingStopsBothSides() {
        let data = (0..<50_000).map { UInt8($0 % 7) }
        let r = transfer([("data", data)], cancelAfter: 4_000)
        XCTAssertLessThan(r.received["data"]?.count ?? 0, data.count)
        XCTAssertTrue(r.errors.contains { $0.hasPrefix("sender") }, "\(r.errors)")
        XCTAssertFalse(r.senderEnded)
    }

    func testNothingToSendEndsAtOnce() {
        let r = transfer([])
        XCTAssertTrue(r.receiverEnded)
        XCTAssertTrue(r.senderEnded)
        XCTAssertEqual(r.received, [:])
    }

    func testWhatFollowsOverAndOutGoesBackToTheTerminal() {
        let receiver = ZModemReceiver()
        var trailing: [UInt8]?
        receiver.onFinished = { trailing = $0 }
        receiver.start()
        receiver.feed(ZModemEncoder().hexHeader(ZModemHeader(type: .fin)))
        receiver.feed(bytes("OO$ prompt"))
        XCTAssertEqual(trailing, bytes("$ prompt"))
    }

    func testSkippingTheCurrentFileMovesOnToTheNext() {
        var queue: [() -> Void] = []
        let a = (0..<200_000).map { UInt8($0 % 13) }
        let files = [("a", a), ("b", bytes("bee"))].map { name, data in
            ZModemOutgoingFile(info: ZModemFileInfo(name: name, size: UInt64(data.count), mtime: nil, mode: nil)) { o, n in
                Array(data[Int(o)..<min(data.count, Int(o) + n)])
            }
        }
        let sender = ZModemSender(files: files)
        let receiver = ZModemReceiver()
        var got: [String: [UInt8]] = [:]
        var current = ""
        var done: [Int: Bool] = [:]
        var ended = false
        sender.schedule = { queue.append($0) }
        sender.toRemote = { b in queue.append { receiver.feed(b) } }
        receiver.toRemote = { b in queue.append { sender.feed(b) } }
        receiver.onOffer = { info in current = info.name; got[info.name] = []; receiver.accept() }
        receiver.onData = { d in
            got[current]! += d
            if current == "a" && got["a"]!.count >= 2048 { receiver.skipCurrent() }
        }
        sender.onFileDone = { done[$0] = $1 }
        receiver.onFinished = { _ in ended = true }
        receiver.start()
        while !queue.isEmpty { queue.removeFirst()() }
        XCTAssertLessThan(got["a"]?.count ?? 0, a.count)
        XCTAssertEqual(got["b"], bytes("bee"))
        XCTAssertEqual(done[0], true, "the sender saw the skip")
        XCTAssertTrue(ended)
    }

    // MARK: Review fixes

    /// Review: the sender pushed a whole file at once (a 500 MB upload sat in memory and ignored
    /// cancel). It now asks for an ack (ZCRCQ) every 64 KiB and keeps at most a window ahead.
    func testTheSenderWaitsForAcksBeyondItsWindow() {
        var queue: [() -> Void] = []
        let data = (0..<1_000_000).map { UInt8($0 % 251) }
        let sender = ZModemSender(files: [ZModemOutgoingFile(info: ZModemFileInfo(name: "big", size: UInt64(data.count), mtime: nil, mode: nil)) { o, n in
            Array(data[Int(o)..<min(data.count, Int(o) + n)])
        }])
        sender.schedule = { queue.append($0) }
        var sent = 0
        var decoder = ZModemDecoder()
        var progress: [UInt64] = []
        sender.onProgress = { _, n in progress.append(n) }
        sender.toRemote = { bytes in
            for event in decoder.feed(bytes) { if case .data(let d, _) = event { sent += d.count } }
        }
        let encoder = ZModemEncoder()
        sender.feed(encoder.hexHeader(ZModemHeader(type: .rinit, flags: ZModemReceiver.capabilities)))
        sender.feed(encoder.hexHeader(ZModemHeader(type: .rpos, position: 0)))
        while !queue.isEmpty { queue.removeFirst()() }
        XCTAssertLessThanOrEqual(sent, ZModemSender.window + ZModemSender.blockSize, "no acks: no more than a window in flight")
        XCTAssertGreaterThan(sent, 0)
        sender.feed(encoder.hexHeader(ZModemHeader(type: .ack, position: UInt32(ZModemSender.window))))
        while !queue.isEmpty { queue.removeFirst()() }
        XCTAssertGreaterThan(sent, ZModemSender.window + ZModemSender.blockSize, "an ack lets the next window go")
        XCTAssertLessThan(progress.last ?? 0, UInt64(sent), "progress is what the receiver confirmed, not what was queued")
    }

    /// Review: output full of '*' copied the rest of the chunk for every false start.
    func testTheSentryIsQuickOnStars() {
        let sentry = ZModemSentry()
        let stars = [UInt8](repeating: UInt8(ascii: "*"), count: 256 * 1024) + Array(" end".utf8)
        let start = Date()
        let r = sentry.feed(stars)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.25, "linear in the chunk")
        XCTAssertEqual(r.toTerminal, stars)
    }

    /// Review: after an upload, the tail of the receiver's ZFIN header (CR and 0x8A) reached
    /// the terminal as a stray glyph.
    func testTheSenderGivesBackOnlyWhatFollowsOverAndOut() {
        let sender = ZModemSender(files: [])
        var rest: [UInt8]?
        sender.toRemote = { _ in }
        sender.onFinished = { rest = $0 }
        let encoder = ZModemEncoder()
        sender.feed(encoder.hexHeader(ZModemHeader(type: .rinit, flags: 0x23)))
        sender.feed(encoder.hexHeader(ZModemHeader(type: .fin)) + Array("$ ".utf8))
        XCTAssertEqual(rest, Array("$ ".utf8))
    }
}
