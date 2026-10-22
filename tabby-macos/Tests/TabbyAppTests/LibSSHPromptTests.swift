#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbySSHLib
@testable import TabbyApp

/// The library backend's host-key card: "Remember in known_hosts" for a new key; a warning
/// with both fingerprints, and Reject as the default button, for a changed one.
@MainActor
final class LibSSHPromptTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    func testDecisions() {
        XCTAssertEqual(HostKeyPromptCard.decision(accept: true, remember: true), .acceptAndRemember)
        XCTAssertEqual(HostKeyPromptCard.decision(accept: true, remember: false), .acceptOnce)
        XCTAssertEqual(HostKeyPromptCard.decision(accept: false, remember: true), .reject)
    }

    func testCardTexts() {
        let new = HostKeyPromptCard.Texts(host: "prod:2222", changed: false)
        XCTAssertEqual(new.title, "Verify host key")
        XCTAssertTrue(new.message.contains("first connection to prod:2222"))
        XCTAssertEqual(new.confirm, "Accept")
        XCTAssertFalse(new.rejectIsDefault)
        let changed = HostKeyPromptCard.Texts(host: "prod:2222", changed: true)
        XCTAssertEqual(changed.title, "Warning: remote host's key has suddenly changed!")
        XCTAssertTrue(changed.message.contains("man-in-the-middle"))
        XCTAssertEqual(changed.confirm, "Accept new key")
        XCTAssertTrue(changed.rejectIsDefault)
    }

    // Synchronous, pumping the run loop like PromptTests: an async test would hold the main
    // actor and the presenter's task could not run.
    private func answer(_ request: HostKeyRequest, pressing characters: String, code: UInt16) throws -> HostKeyDecision {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let window = try XCTUnwrap(c.window)
        var decision: HostKeyDecision?
        Task { decision = await LibSSHPromptPresenter.shared.verifyHostKey(request, in: window) }
        TestApp.pump(until: { window.attachedSheet != nil })
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.performKeyEquivalent(with: key(characters, code: code, in: sheet)))
        TestApp.pump(until: { decision != nil })
        return try XCTUnwrap(decision)
    }

    func testReturnAcceptsAndRemembersANewKey() throws {
        let request = HostKeyRequest(host: "prod", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:new", previousFingerprint: nil)
        let decision = try answer(request, pressing: "\r", code: 36)
        XCTAssertEqual(decision, .acceptAndRemember)
    }

    func testReturnRejectsAChangedKey() throws {
        let request = HostKeyRequest(host: "prod", port: 22, keyType: "ssh-ed25519", fingerprint: "SHA256:new", previousFingerprint: "SHA256:old")
        let decision = try answer(request, pressing: "\r", code: 36)
        XCTAssertEqual(decision, .reject)
    }
}
#endif
