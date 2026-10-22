#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbyApp

@MainActor
final class PromptTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    private func subviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(subviews) }

    private func key(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// The fingerprint sits in its own monospaced, selectable field that wraps at any character
    /// and never hyphenates, so it reads exactly as `ssh-keygen -l` prints it. In an alert's
    /// informative text AppKit hyphenated it ("…Jbq1w-" / "p3V…").
    func testHostKeyCardShowsTheFingerprintVerbatim() throws {
        let fingerprint = "SHA256:st+0bOhmDJbq1wp3VUeiF5u78/zwSK9ZH/7VIaagytQ"
        let host = NSHostingView(rootView: HostKeyPromptCard(host: "localhost (::1)", keyType: "ED25519", fingerprint: fingerprint) { _ in }
            .chromeEnvironment())
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 360)
        host.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(subviews(host).compactMap { $0 as? NSTextField }.first { $0.stringValue == fingerprint })
        XCTAssertTrue(field.isSelectable)
        XCTAssertEqual(field.lineBreakMode, NSLineBreakMode.byCharWrapping)
        let style = field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.hyphenationFactor ?? 0, 0)
    }

    /// The paste warning is a card sheet in the design's style; Esc cancels, ↩ pastes.
    func testPasteWarningIsACardSheet() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let window = try XCTUnwrap(c.window)
        var result: Bool?
        Prompts.confirmPaste(in: window, text: "cd /srv\ngit pull\nmake") { result = $0 }
        var sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertNotNil(sheet.contentViewController as? NSHostingController<AnyView>, "a SwiftUI card, not an NSAlert")
        XCTAssertTrue(sheet.performKeyEquivalent(with: key("\u{1b}", code: 53, in: sheet)))
        TestApp.pump(until: { result != nil })
        XCTAssertEqual(result, false)
        TestApp.pump(until: { window.attachedSheet == nil })

        result = nil
        Prompts.confirmPaste(in: window, text: "a\nb") { result = $0 }
        sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertTrue(sheet.performKeyEquivalent(with: key("\r", code: 36, in: sheet)))
        TestApp.pump(until: { result != nil })
        XCTAssertEqual(result, true)
    }

    func testTextPromptReturnsTheValue() throws {
        let c = WindowManager.shared.newWindow(openDefaultTab: false)
        defer { TestApp.dispose(c) }
        let window = try XCTUnwrap(c.window)
        var result: String??
        Prompts.text(in: window, title: "Rename tab", value: "prod-web-01", confirm: "Rename") { value, _ in result = .some(value) }
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertNotNil(sheet.contentViewController as? NSHostingController<AnyView>)
        XCTAssertTrue(sheet.performKeyEquivalent(with: key("\r", code: 36, in: sheet)))
        TestApp.pump(until: { result != nil })
        XCTAssertEqual(result, .some("prod-web-01"))
    }
}
#endif
