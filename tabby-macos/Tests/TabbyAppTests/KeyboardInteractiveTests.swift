#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbySSHLib
@testable import TabbyApp

/// The inline keyboard-interactive panel's model (design `sshAuth`, Tabby's
/// KeyboardInteractiveAuthComponent): one prompt at a time, Back keeps answers, Remember only
/// for password-like prompts, Cancel ends the login.
@MainActor
final class KeyboardInteractiveTests: XCTestCase {
    func round(instruction: String = "", prefilled: [String?] = ["s3cret", nil]) -> KeyboardInteractiveRound {
        KeyboardInteractiveRound(host: "db.internal", name: "OTP", instruction: instruction,
                                 prompts: [.init(text: "Password:", echo: false), .init(text: "Verification code:", echo: true)],
                                 prefilled: prefilled)
    }

    func testStepsThroughThePromptsAndAnswersOnce() {
        var results: [KeyboardInteractiveAnswer?] = []
        let model = KeyboardInteractiveModel(round: round()) { results.append($0) }
        XCTAssertEqual(model.counter, "keyboard-interactive · prompt 1 of 2")
        XCTAssertEqual(model.answer, "s3cret", "the saved password is filled in, but not sent by itself")
        XCTAssertTrue(model.isSecure)
        XCTAssertTrue(model.showsRemember)
        XCTAssertFalse(model.canGoBack)
        model.remember = true
        model.proceed()
        XCTAssertEqual(model.counter, "keyboard-interactive · prompt 2 of 2")
        XCTAssertFalse(model.isSecure, "echoed prompts are plain fields")
        XCTAssertFalse(model.showsRemember)
        XCTAssertTrue(model.canGoBack)
        XCTAssertTrue(results.isEmpty)
        model.answer = "4821"
        model.proceed()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first??.answers, ["s3cret", "4821"])
        XCTAssertEqual(results.first??.remember, true)
        model.proceed()
        model.cancel()
        XCTAssertEqual(results.count, 1, "answered once")
    }

    func testBackKeepsWhatWasTyped() {
        let model = KeyboardInteractiveModel(round: round(prefilled: [nil, nil])) { _ in }
        model.answer = "first"
        model.proceed()
        model.answer = "second"
        model.goBack()
        XCTAssertEqual(model.answer, "first")
        model.proceed()
        XCTAssertEqual(model.answer, "second")
    }

    func testCancelEndsTheLogin() {
        var results: [KeyboardInteractiveAnswer?] = []
        let model = KeyboardInteractiveModel(round: round()) { results.append($0) }
        model.cancel()
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0])
    }

    private func views(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(views) }

    /// The panel sits above the terminal and pushes it down; it goes when answered.
    func testThePaneShowsThePanelAboveTheTerminal() throws {
        TestApp.boot()
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        c.model.openTab()
        let window = try XCTUnwrap(c.window)
        TestApp.pump(until: { self.views(window.contentView!).contains { $0 is PaneContainerView } })
        let container = try XCTUnwrap(views(window.contentView!).compactMap { $0 as? PaneContainerView }.first)
        let pane = container.pane
        var result: KeyboardInteractiveAnswer??
        Task { result = .some(await KeyboardInteractivePanels.shared.ask(self.round(), in: pane.id)) }
        TestApp.pump(until: { container.subviews.contains { $0 is NSHostingView<KeyboardInteractivePanel> } })
        let panel = try XCTUnwrap(container.subviews.first { $0 is NSHostingView<KeyboardInteractivePanel> })
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.minY, 0, accuracy: 0.5)
        XCTAssertGreaterThan(panel.frame.height, 40)
        XCTAssertEqual(container.engine.frame.minY, panel.frame.maxY, accuracy: 0.5, "the terminal starts below the panel")
        XCTAssertEqual(container.engine.frame.height, container.bounds.height - panel.frame.height, accuracy: 0.5)

        KeyboardInteractivePanels.shared.models[pane.id]?.cancel()
        TestApp.pump(until: { result != nil })
        XCTAssertEqual(result, .some(nil))
        TestApp.pump(until: { !container.subviews.contains { $0 is NSHostingView<KeyboardInteractivePanel> } })
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.engine.frame, container.bounds)
    }

    func testLinksInTheInstruction() {
        let model = KeyboardInteractiveModel(round: round(instruction: "Approve at https://sso.example.com/device?code=AB12. Then type the code.")) { _ in }
        XCTAssertEqual(model.links, [URL(string: "https://sso.example.com/device?code=AB12")!])
    }
}
#endif
