#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyApp

/// Design C10: closing a tab with a live connection asks with Cancel / Close, where Close is
/// destructive and Return does not answer it; quitting asks with Quit as the default.
@MainActor
final class ConfirmationAlertTests: XCTestCase {
    func testADestructiveConfirmHasNoReturnKey() {
        let alert = Prompts.confirmAlert(title: "Close this tab?", message: "Disconnect from switch.lan?", confirm: "Close",
                                         destructive: true)
        XCTAssertEqual(alert.messageText, "Close this tab?")
        XCTAssertEqual(alert.informativeText, "Disconnect from switch.lan?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Close", "Cancel"])
        XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "", "↩ does not close a live connection")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}", "esc cancels")
    }

    func testAnOrdinaryConfirmKeepsReturn() {
        let alert = Prompts.confirmAlert(title: "Reconnect to h?", message: "", confirm: "Reconnect", destructive: false)
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertFalse(alert.buttons[0].hasDestructiveAction)
    }

    func testQuitIsTheDefault() {
        let alert = AppDelegate.quitAlert(warnings: ["Disconnect from switch.lan?"])
        XCTAssertEqual(alert.messageText, "Quit TabbyMac?")
        XCTAssertEqual(alert.informativeText, "Disconnect from switch.lan?")
        XCTAssertEqual(alert.buttons.map(\.title), ["Quit", "Cancel"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertFalse(alert.buttons[0].hasDestructiveAction)
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
    }
}
#endif
