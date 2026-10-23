#if canImport(AppKit)
import XCTest
import AppKit
import TabbyCore
import TabbySerial
import TabbyTerminal
import TabbyTestSupport
@testable import TabbyApp

/// Design C2: the chip's "Baud rate" opens a popover of the standard rates (the one in use
/// checked) with a Custom field; a rate applies at once, ↩ applies the custom one.
@MainActor
final class BaudRatePopoverTests: XCTestCase {
    func makeModel(current: Int? = 115200) -> (BaudRatePopoverModel, () -> [Int]) {
        var applied: [Int] = []
        let model = BaudRatePopoverModel(device: "cu.usbserial-1420", current: current) { applied.append($0) }
        return (model, { applied })
    }

    func testItListsTheStandardRatesWithTheOneInUse() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.rates, BaudRates.standard)
        XCTAssertTrue(model.isCurrent(115200))
        XCTAssertFalse(model.isCurrent(9600))
        XCTAssertEqual(model.custom, "", "a standard rate in use leaves Custom empty")
        XCTAssertEqual(makeModel(current: 250000).0.custom, "250000", "a custom rate in use shows in the field")
    }

    func testChoosingARateAppliesItAndCloses() {
        let (model, applied) = makeModel()
        model.choose(9600)
        XCTAssertEqual(applied(), [9600])
        XCTAssertTrue(model.isFinished)
    }

    func testReturnAppliesTheCustomRate() {
        let (model, applied) = makeModel()
        model.custom = " 250000 "
        model.submit()
        XCTAssertEqual(applied(), [250000])
        XCTAssertTrue(model.isFinished)
    }

    func testAnInvalidCustomRateDoesNothing() {
        for text in ["", "abc", "0", "-9600", "96 00"] {
            let (model, applied) = makeModel()
            model.custom = text
            model.submit()
            XCTAssertEqual(applied(), [], "\"\(text)\"")
            XCTAssertFalse(model.isFinished)
        }
    }

    /// The chip builds the popover from the open port: its device name and the rate in use,
    /// and applying changes the port at once (as the selector did before the design).
    func testTheChipsPopoverChangesTheOpenPort() throws {
        TestApp.boot()
        let pty = try PTYPair()
        let model = WindowModel()
        defer { for tab in model.tabs { for pane in tab.orderedPanes { pane.close() } } }
        model.openTab(profile: Profile(type: "serial", name: "s", options: ["port": .string(pty.replicaPath), "baudrate": 9600]))
        let pane = try XCTUnwrap(model.activePane)
        pane.start()
        let popover = try XCTUnwrap(SerialChip.popoverModel(for: pane))
        XCTAssertEqual(popover.device, (pty.replicaPath as NSString).lastPathComponent)
        XCTAssertTrue(popover.isCurrent(9600))
        popover.choose(57600)
        XCTAssertEqual(SerialChip.serialSession(of: pane)?.baudRate, 57600)
        XCTAssertEqual(SerialOptions(pane.profile.options).baudrate, 57600)
    }

    /// A rate the port refuses shows the design's error toast (C2b).
    func testARefusedRateShowsTheToast() throws {
        TestApp.boot()
        let pty = try PTYPair()
        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(controller) }
        controller.model.openTab(profile: Profile(type: "serial", name: "s", options: ["port": .string(pty.replicaPath), "baudrate": 9600]))
        let pane = try XCTUnwrap(controller.model.tabs.last?.focusedPane)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        TestApp.pump(until: { SerialChip.serialSession(of: pane) != nil })
        SerialChip.apply(0, to: pane)
        let toast = try XCTUnwrap(controller.toasts.toasts.last)
        XCTAssertEqual(toast.title, "Could not change the baud rate")
        XCTAssertEqual(toast.detail, "Unsupported baud rate 0")
    }
}
#endif
