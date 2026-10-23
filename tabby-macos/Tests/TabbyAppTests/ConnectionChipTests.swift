#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
@testable import TabbyCore
@testable import TabbyApp

@MainActor
final class ConnectionChipTests: XCTestCase {
    func pixels(_ text: Text) -> Data? {
        let renderer = ImageRenderer(content: text.font(.custom("Menlo", size: 12)).environment(\.locale, Locale(identifier: "vi_VN")))
        renderer.scale = 2
        return renderer.nsImage?.tiffRepresentation
    }

    /// Found in the M6 walk on a Mac set to Vietnamese: the chip read `tester@127.0.0.1:2.222`
    /// because SwiftUI formats an interpolated Int with the locale's digit grouping. A port is
    /// not a quantity and is never grouped.
    func testTheAddressNeverGroupsThePortsDigits() throws {
        let profile = Profile(type: "ssh", name: "t", options: ["host": "127.0.0.1", "port": 2222, "user": "tester"])
        let chip = try XCTUnwrap(pixels(ConnectionChip.addressText(for: profile)))
        let grouped = try XCTUnwrap(pixels(Text(verbatim: "tester@127.0.0.1:2.222")))
        let plain = try XCTUnwrap(pixels(Text(verbatim: "tester@127.0.0.1:2222")))
        XCTAssertNotEqual(grouped, plain, "the renderer tells the two apart")
        XCTAssertEqual(chip, plain, "the chip shows 2222, not 2.222")
    }

    func testTheChipNamesTheConnectionByType() {
        func address(_ type: String, _ options: ConfigValue, baud: Int? = nil) -> String {
            ConnectionChip.address(for: Profile(type: type, name: "Name", options: options), baudRate: baud)
        }
        XCTAssertEqual(address("ssh", ["host": "h", "port": 2222, "user": "me"]), "me@h:2222")
        XCTAssertEqual(address("telnet", ["host": "router", "port": 2323]), "router:2323")
        XCTAssertEqual(address("telnet", ["host": "::1"]), "[::1]:23")
        XCTAssertEqual(address("serial", ["port": "/dev/cu.usbserial-1420", "baudrate": 9600]), "cu.usbserial-1420 · 9600")
        XCTAssertEqual(address("serial", ["port": "/dev/cu.usbserial-1420", "baudrate": 9600], baud: 57600),
                       "cu.usbserial-1420 · 57600", "the rate in use wins")
        XCTAssertEqual(address("serial", ["port": "/dev/cu.usbserial-1420"]), "cu.usbserial-1420")
        XCTAssertEqual(address("serial", [:]), "Name")
    }
}
#endif
