#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbyCore
@testable import TabbyApp

@MainActor
final class SSHStatusChipTests: XCTestCase {
    func pixels(_ text: Text) -> Data? {
        let renderer = ImageRenderer(content: text.font(.custom("Menlo", size: 12)).environment(\.locale, Locale(identifier: "vi_VN")))
        renderer.scale = 2
        return renderer.nsImage?.tiffRepresentation
    }

    /// Found in the M6 walk on a Mac set to Vietnamese: the chip read `tester@127.0.0.1:2.222`
    /// because SwiftUI formats an interpolated Int with the locale's digit grouping. A port is
    /// not a quantity and is never grouped.
    func testTheAddressNeverGroupsThePortsDigits() throws {
        let options = SSHOptions(.object(["host": .string("127.0.0.1"), "port": .int(2222), "user": .string("tester")]))
        let chip = try XCTUnwrap(pixels(SSHStatusChip.address(options)))
        let grouped = try XCTUnwrap(pixels(Text(verbatim: "tester@127.0.0.1:2.222")))
        let plain = try XCTUnwrap(pixels(Text(verbatim: "tester@127.0.0.1:2222")))
        XCTAssertNotEqual(grouped, plain, "the renderer tells the two apart")
        XCTAssertEqual(chip, plain, "the chip shows 2222, not 2.222")
    }
}
#endif
