#if canImport(AppKit)
import XCTest
import TabbyCore
@testable import TabbyApp

/// The three serial selectors as designed (C3 baud rate, C4 port, C5 Show Serial
/// connections), built by the functions the app presents.
@MainActor
final class SerialSelectorsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestApp.boot()
    }

    let ports = [SerialPortInfo(path: "/dev/cu.debug-console"),
                 SerialPortInfo(path: "/dev/cu.usbserial-1420", description: "FTDI FT3K2PQ1"),
                 SerialPortInfo(path: "/dev/cu.usbmodem2101")]

    func testThePortSelectorListsExternalPortsThenDimmedBuiltInOnes() {
        let config = SerialSelectors.portSelector(ports: ports) { _ in }
        XCTAssertEqual(config.placeholder, "Serial port or a device path")
        XCTAssertEqual(config.items.map(\.title), ["cu.usbserial-1420", "cu.usbmodem2101", "cu.debug-console"])
        XCTAssertEqual(config.items.map(\.subtitle), ["FTDI FT3K2PQ1", "/dev/cu.usbmodem2101", "/dev/cu.debug-console"])
        XCTAssertEqual(config.items.map(\.group), ["Ports", "Ports", "Built in"])
        XCTAssertEqual(config.items.map(\.isDimmed), [false, false, true])
        XCTAssertEqual(Set(config.items.compactMap(\.icon)), ["cable.connector"])
        XCTAssertEqual(config.emptyState, SelectorEmptyState(icon: "cable.connector", title: "No ports found",
                                                             subtitle: "Connect a device, or type its path"))
        XCTAssertNil(config.trailingHint)
    }

    func testATypedPathLeadsThePortList() throws {
        var chosen: String?
        let config = SerialSelectors.portSelector(ports: ports) { chosen = $0 }
        XCTAssertTrue(config.dynamicItemsFirst)
        let rows = try XCTUnwrap(config.dynamicItems?("/dev/cu.debug-console"))
        XCTAssertEqual(rows.map(\.title), ["Use /dev/cu.debug-console"])
        XCTAssertEqual(rows.first?.icon, "pencil")
        XCTAssertEqual(rows.first?.group, "")
        rows.first?.action()
        XCTAssertEqual(chosen, "/dev/cu.debug-console")
        XCTAssertEqual(config.dynamicItems?("usb").count, 0, "only paths")
        XCTAssertEqual(config.dynamicItems?("~/dev/x").first?.title, "Use \(NSHomeDirectory())/dev/x")
    }

    func testTheBaudSelectorPreselects115200AndTakesACustomRate() throws {
        var chosen: Int?
        let config = SerialSelectors.baudSelector { chosen = $0 }
        XCTAssertEqual(config.placeholder, "Baud rate")
        XCTAssertEqual(config.items.map(\.title), BaudRates.standard.map(String.init))
        XCTAssertEqual(config.items[config.initialSelection].title, "115200")
        XCTAssertNil(config.trailingHint)
        let custom = try XCTUnwrap(config.dynamicItems?("250000").first)
        XCTAssertEqual(custom.title, "Use custom rate \u{201C}250000\u{201D}")
        XCTAssertEqual(custom.icon, "pencil")
        custom.action()
        XCTAssertEqual(chosen, 250000)
        XCTAssertEqual(config.dynamicItems?("9600").count, 0, "a standard rate is in the list")
        XCTAssertEqual(config.dynamicItems?("0").count, 0)
    }

    func testShowSerialConnectionsListsSavedProfilesTheTemplateThenPorts() {
        let provider = SerialProfileProvider(ports: { self.ports })
        let saved = Profile(id: "router", type: "serial", name: "Router console", options: ["port": "/dev/cu.usbserial-1420"], color: "#56c8d8")
        let config = SerialSelectors.connectionsSelector(profiles: provider.builtinProfiles() + [saved], provider: provider) { _ in }
        XCTAssertEqual(config.placeholder, "Serial port or profile")
        XCTAssertEqual(config.items.map(\.title), ["Router console", "Serial connection", "Serial: FTDI FT3K2PQ1", "Serial: cu.usbmodem2101"])
        XCTAssertEqual(config.items.map(\.group), ["Saved profiles", "", "Ports", "Ports"])
        XCTAssertEqual(config.items[1].subtitle, "Asks for the port and baud rate")
        XCTAssertEqual(config.items[1].icon, "plus")
        XCTAssertEqual(config.items[2].subtitle, "/dev/cu.usbserial-1420")
        XCTAssertEqual(config.items[0].color, "#56c8d8")
        XCTAssertEqual(config.trailingHint, StartPageView.shortcut("serial").map { "\($0) serial" })
        XCTAssertNotNil(config.trailingHint, "⌥K is bound by default")
    }

    func testAPathWithARateIsAQuickConnectRowFirst() throws {
        let provider = SerialProfileProvider(ports: { self.ports })
        var opened: Profile?
        let config = SerialSelectors.connectionsSelector(profiles: [], provider: provider) { opened = $0 }
        XCTAssertTrue(config.dynamicItemsFirst)
        let row = try XCTUnwrap(config.dynamicItems?("/dev/cu.usbserial-1420@9600").first)
        XCTAssertEqual(row.title, "Quick connect")
        XCTAssertEqual(row.subtitle, "/dev/cu.usbserial-1420 at 9600 baud")
        XCTAssertEqual(row.icon, "bolt")
        row.action()
        XCTAssertEqual(SerialOptions(try XCTUnwrap(opened).options).baudrate, 9600)
        XCTAssertEqual(config.dynamicItems?("router").count, 0, "only paths")
    }
}
#endif
