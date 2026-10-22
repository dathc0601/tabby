#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyApp

@MainActor
final class PromptTests: XCTestCase {
    /// The fingerprint sits in its own monospaced, selectable field that wraps at any character
    /// and never hyphenates, so it reads exactly as `ssh-keygen -l` prints it. In the alert's
    /// informative text AppKit hyphenated it ("…Jbq1w-" / "p3V…").
    func testHostKeyAlertShowsTheFingerprintVerbatim() throws {
        let fingerprint = "SHA256:st+0bOhmDJbq1wp3VUeiF5u78/zwSK9ZH/7VIaagytQ"
        let alert = SSHPromptPresenter.hostKeyAlert(host: "localhost (::1)", keyType: "ED25519", fingerprint: fingerprint)
        let field = try XCTUnwrap(alert.accessoryView as? NSTextField)
        XCTAssertEqual(field.stringValue, fingerprint)
        XCTAssertTrue(field.isSelectable)
        XCTAssertEqual(field.lineBreakMode, NSLineBreakMode.byCharWrapping)
        let style = field.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.hyphenationFactor ?? 0, 0)
        XCTAssertFalse(alert.informativeText.contains(fingerprint))
        XCTAssertTrue(alert.informativeText.contains("ED25519"))
    }
}
#endif
