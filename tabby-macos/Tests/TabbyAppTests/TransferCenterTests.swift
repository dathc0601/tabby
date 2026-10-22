#if canImport(AppKit)
import XCTest
@testable import TabbyApp

/// Transfers behind the tab bar's transfers popover (Tabby's transfers menu).
@MainActor
final class TransferCenterTests: XCTestCase {
    func testATransferRunsToCompletion() async {
        let center = TransferCenter()
        let transfer = await center.run(name: "db.sql.gz", direction: .upload, host: "prod", total: 1000) { report, _ in
            report(400)
            report(600)
        }
        XCTAssertEqual(transfer.status, .done)
        XCTAssertEqual(transfer.progress.completed, 1000)
        XCTAssertEqual(transfer.progress.fraction, 1)
        XCTAssertEqual(center.transfers.count, 1)
        XCTAssertEqual(center.activeCount, 0)
        XCTAssertEqual(transfer.subtitle, "To prod")
    }

    func testAFailureAndACancelKeepTheirReason() async {
        let center = TransferCenter()
        struct Boom: LocalizedError { var errorDescription: String? { "Permission denied" } }
        let failed = await center.run(name: "a", direction: .download, host: "h", total: 10) { _, _ in throw Boom() }
        XCTAssertEqual(failed.status, .failed("Permission denied"))
        XCTAssertEqual(failed.subtitle, "From h")
        var transfer: Transfer?
        let cancelled = await center.run(name: "b", direction: .download, host: "h", total: 10, started: { transfer = $0 }) { report, isCancelled in
            transfer?.cancel()
            if isCancelled() { throw CancellationError() }
            report(10)
        }
        XCTAssertEqual(cancelled.status, .cancelled)
    }

    func testClearingFinishedKeepsRunningOnesAndAsksFirst() async {
        let center = TransferCenter()
        _ = await center.run(name: "done", direction: .upload, host: "h", total: 1) { report, _ in report(1) }
        let running = center.start(name: "running", direction: .upload, host: "h", total: 100)
        XCTAssertEqual(center.activeCount, 1)
        XCTAssertTrue(center.clearNeedsConfirmation, "There are active file transfers")
        center.clearFinished()
        XCTAssertEqual(center.transfers.map(\.name), ["running"])
        center.abortAll()
        XCTAssertEqual(running.status, .cancelled)
        XCTAssertFalse(center.clearNeedsConfirmation)
    }

    func testTheFirstTransferAsksToShowThePopover() {
        let center = TransferCenter()
        XCTAssertFalse(center.wantsPopover)
        _ = center.start(name: "x", direction: .download, host: "h", total: 1)
        XCTAssertTrue(center.wantsPopover)
        center.wantsPopover = false
        _ = center.start(name: "y", direction: .download, host: "h", total: 1)
        XCTAssertFalse(center.wantsPopover, "only when the list was empty")
    }
}
#endif
