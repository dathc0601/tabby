#if os(macOS)
import XCTest
import CryptoKit
@testable import TabbyCore

/// Phase 6: TabbyMac's ZMODEM against lrzsz's `sz` and `rz`, over pipes into Docker
/// (`scripts/lrzsz-image.sh` builds the image). Skipped without Docker or the image.
final class ZModemInteropTests: XCTestCase {
    static let image = "tabbymac-lrzsz:1"
    let queue = DispatchQueue(label: "zmodem-interop")

    func docker() throws -> String {
        let candidates = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
        guard let path = candidates.first(where: FileManager.default.isExecutableFile) else { throw XCTSkip("no docker") }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: path)
        check.arguments = ["image", "inspect", Self.image]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        guard check.terminationStatus == 0 else { throw XCTSkip("no \(Self.image) image (scripts/lrzsz-image.sh)") }
        return path
    }

    /// Runs `script` in the image with stdin/stdout piped; `output` gets stdout on `queue`.
    func run(_ script: String, output: @escaping ([UInt8]) -> Void) throws -> (Process, FileHandle) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try docker())
        p.arguments = ["run", "--rm", "-i", Self.image, "sh", "-c", script]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [queue] h in
            let data = h.availableData
            guard !data.isEmpty else { return }
            queue.async { output(Array(data)) }
        }
        try p.run()
        addTeardownBlock { if p.isRunning { p.terminate() } }
        return (p, stdin.fileHandleForWriting)
    }

    /// Deterministic content both sides can make: the numbers 1…40000, one per line.
    static let numbers = Array((1...40000).map { "\($0)\n" }.joined().utf8)

    func testReceivingFromSz() throws {
        var received: [UInt8] = []
        var offered: ZModemFileInfo?
        var errors: [String] = []
        let done = DispatchSemaphore(value: 0)
        let sentry = ZModemSentry()
        let receiver = ZModemReceiver()
        var stdinHandle: FileHandle?
        var detected = false
        receiver.toRemote = { bytes in try? stdinHandle?.write(contentsOf: Data(bytes)) }
        receiver.onOffer = { info in offered = info; receiver.accept() }
        receiver.onData = { received += $0 }
        receiver.onFinished = { _ in done.signal() }
        receiver.onError = { errors.append($0); done.signal() }
        let (process, stdin) = try run("seq 1 40000 > '/tmp/num bers.txt' && sz '/tmp/num bers.txt'") { bytes in
            if detected { receiver.feed(bytes); return }
            let r = sentry.feed(bytes)
            if r.detection == .receive {
                detected = true
                receiver.start()
                receiver.feed(r.protocolBytes)
            }
        }
        stdinHandle = stdin
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success, "the session ended")
        queue.sync {}
        try? stdin.close()
        process.waitUntilExit()
        XCTAssertEqual(errors, [])
        XCTAssertEqual(offered?.name, "num bers.txt")
        XCTAssertEqual(offered?.size, UInt64(Self.numbers.count))
        XCTAssertEqual(received.count, Self.numbers.count)
        XCTAssertTrue(received == Self.numbers, "the bytes match")
        XCTAssertEqual(process.terminationStatus, 0, "sz is satisfied")
    }

    func testSkippingAFileHalfwayWithSz() throws {
        var received: [String: [UInt8]] = [:]
        var current = ""
        var errors: [String] = []
        let done = DispatchSemaphore(value: 0)
        let sentry = ZModemSentry()
        let receiver = ZModemReceiver()
        var stdinHandle: FileHandle?
        var detected = false
        receiver.toRemote = { bytes in try? stdinHandle?.write(contentsOf: Data(bytes)) }
        receiver.onOffer = { info in current = info.name; received[info.name] = []; receiver.accept() }
        receiver.onData = { data in
            received[current]! += data
            if current == "big" && received["big"]!.count > 100_000 { receiver.skipCurrent() }
        }
        receiver.onFinished = { _ in done.signal() }
        receiver.onError = { errors.append($0); done.signal() }
        let (process, stdin) = try run("cd /tmp && head -c 3000000 /dev/zero > big && echo small > small && sz big small") { bytes in
            if detected { receiver.feed(bytes); return }
            let r = sentry.feed(bytes)
            if r.detection == .receive {
                detected = true
                receiver.start()
                receiver.feed(r.protocolBytes)
            }
        }
        stdinHandle = stdin
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success)
        queue.sync {}
        try? stdin.close()
        process.waitUntilExit()
        XCTAssertEqual(errors, [])
        XCTAssertLessThan(received["big"]?.count ?? 0, 3_000_000)
        XCTAssertEqual(received["small"], Array("small\n".utf8), "sz went on to the next file")
    }

    func testSendingToRz() throws {
        let big = (0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) }
        let files: [(String, [UInt8])] = [("first file.txt", Array("hello\n".utf8)), ("data.bin", big)]
        let outgoing = files.map { name, data in
            ZModemOutgoingFile(info: ZModemFileInfo(name: name, size: UInt64(data.count), mtime: nil, mode: 0o644)) { offset, count in
                Array(data[Int(offset)..<min(data.count, Int(offset) + count)])
            }
        }
        var tail: [UInt8] = []
        var errors: [String] = []
        var done: [Int: Bool] = [:]
        let finished = DispatchSemaphore(value: 0)
        let sentry = ZModemSentry()
        let sender = ZModemSender(files: outgoing)
        var stdinHandle: FileHandle?
        var detected = false, over = false
        sender.schedule = { [queue] in queue.async(execute: $0) }
        sender.toRemote = { bytes in try? stdinHandle?.write(contentsOf: Data(bytes)) }
        sender.onFileDone = { done[$0] = $1 }
        sender.onFinished = { rest in tail += rest; over = true }
        sender.onError = { errors.append($0); finished.signal() }
        let (process, stdin) = try run("cd /tmp && rz && sha256sum 'first file.txt' data.bin; echo END") { bytes in
            if over {
                tail += bytes
                if String(decoding: tail, as: UTF8.self).contains("END") { finished.signal() }
                return
            }
            if detected { sender.feed(bytes); return }
            let r = sentry.feed(bytes)
            if r.detection == .send {
                detected = true
                sender.feed(r.protocolBytes)
            }
        }
        stdinHandle = stdin
        XCTAssertEqual(finished.wait(timeout: .now() + 60), .success)
        queue.sync {}
        try? stdin.close()
        process.waitUntilExit()
        XCTAssertEqual(errors, [])
        XCTAssertEqual(done, [0: false, 1: false])
        let sums = String(decoding: tail, as: UTF8.self)
        for (name, data) in files {
            let hex = SHA256.hash(data: Data(data)).map { String(format: "%02x", $0) }.joined()
            XCTAssertTrue(sums.contains("\(hex)  \(name)"), "\(name) arrived whole: \(sums)")
        }
    }
}
#endif
