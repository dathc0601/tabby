import XCTest
@testable import TabbyCore

/// `serial` profiles: Tabby's `SerialProfilesService` (`tabby-serial/src/profiles.ts`).
final class SerialProfileTests: XCTestCase {
    let ports = [
        SerialPortInfo(path: "/dev/cu.usbserial-1420", description: "FTDI FT3K2PQ1"),
        SerialPortInfo(path: "/dev/cu.usbmodem101", description: nil),
        SerialPortInfo(path: "/dev/cu.debug-console", description: nil),
        SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port", description: nil),
    ]

    private func provider() -> SerialProfileProvider {
        let ports = ports
        return SerialProfileProvider(ports: { ports })
    }

    func testOptionsAndTabbysDefaults() throws {
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        let registry = ProfileRegistry(config: config, providers: [provider()], recents: RecentProfilesStore(url: nil))
        let resolved = registry.resolved(Profile(id: "serial:x", type: "serial", name: "", options: [:]))
        let o = SerialOptions(resolved.options)
        XCTAssertNil(o.port)
        XCTAssertNil(o.baudrate, "null means: ask every time")
        XCTAssertEqual(o.databits, 8)
        XCTAssertEqual(o.stopbits, 1)
        XCTAssertEqual(o.parity, .none)
        XCTAssertFalse(o.rtscts || o.xon || o.xoff || o.xany || o.slowSend)
        XCTAssertEqual(InputProcessing.backspaceMode(resolved.options), "backspace")
        XCTAssertFalse(resolved.clearServiceMessagesOnConnect)

        let custom = SerialOptions(["port": "/dev/cu.a", "baudrate": 9600, "databits": 7, "stopbits": 1.5,
                                    "parity": "even", "rtscts": true, "xon": true, "slowSend": true])
        XCTAssertEqual(custom.port, "/dev/cu.a")
        XCTAssertEqual(custom.baudrate, 9600)
        XCTAssertEqual(custom.databits, 7)
        XCTAssertEqual(custom.stopbits, 1.5)
        XCTAssertEqual(custom.parity, .even)
        XCTAssertTrue(custom.rtscts && custom.xon && custom.slowSend)
        XCTAssertEqual(SerialOptions(["baudrate": "57600"]).baudrate, 57600, "Tabby parses the rate with parseInt")
        XCTAssertNil(SerialOptions(["port": ""]).port)
    }

    func testStandardBaudRates() {
        XCTAssertEqual(BaudRates.standard, [110, 150, 300, 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
                                            230400, 460800, 921600, 1500000])
    }

    func testBuiltinsAreTheTemplateAndOneProfilePerExternalPort() {
        let builtins = provider().builtinProfiles()
        XCTAssertEqual(builtins.map(\.id), ["serial:template", "serial:port-devcu-usbserial-1420", "serial:port-devcu-usbmodem101"])
        XCTAssertEqual(builtins.map(\.name), ["Serial connection", "Serial: FTDI FT3K2PQ1", "Serial: cu.usbmodem101"])
        XCTAssertTrue(builtins[0].isTemplate)
        XCTAssertTrue(builtins.allSatisfy { $0.type == "serial" && $0.isBuiltin && $0.icon == "fas fa-microchip" })
        XCTAssertEqual(SerialOptions(builtins[1].options).port, "/dev/cu.usbserial-1420")
    }

    func testPortInfo() {
        XCTAssertEqual(ports[0].deviceName, "cu.usbserial-1420")
        XCTAssertFalse(ports[0].isInternal)
        XCTAssertTrue(ports[2].isInternal)
        XCTAssertTrue(ports[3].isInternal)
    }

    func testQuickConnect() throws {
        let p = provider()
        let plain = try XCTUnwrap(p.quickConnect("/dev/cu.usbserial-1420"))
        XCTAssertEqual(plain.type, "serial")
        XCTAssertEqual(plain.name, "/dev/cu.usbserial-1420")
        XCTAssertEqual(SerialOptions(plain.options).port, "/dev/cu.usbserial-1420")
        XCTAssertEqual(SerialOptions(plain.options).baudrate, 115200)
        XCTAssertEqual(SerialOptions(try XCTUnwrap(p.quickConnect("/dev/cu.a@9600")).options).baudrate, 9600)
        XCTAssertEqual(SerialOptions(try XCTUnwrap(p.quickConnect("/dev/cu.a:9600")).options).baudrate, 9600)
        XCTAssertEqual(SerialOptions(try XCTUnwrap(p.quickConnect("/dev/cu.a@fast")).options).baudrate, 115200)
        XCTAssertEqual(SerialOptions(try XCTUnwrap(p.quickConnect("/dev/cu.a@fast")).options).port, "/dev/cu.a")
        XCTAssertNil(p.quickConnect(" "))
    }

    func testQuickConnectString() {
        XCTAssertEqual(SerialProfileProvider.quickConnectString(SerialOptions(["port": "/dev/cu.a", "baudrate": 9600])), "/dev/cu.a@9600")
        XCTAssertEqual(SerialProfileProvider.quickConnectString(SerialOptions(["port": "/dev/cu.a", "baudrate": 115200])), "/dev/cu.a")
        XCTAssertEqual(SerialProfileProvider.quickConnectString(SerialOptions(["port": "/dev/cu.a"])), "/dev/cu.a")
        XCTAssertNil(SerialProfileProvider.quickConnectString(SerialOptions([:])))
    }

    /// Design C7: the profile list, start page and selectors describe a serial profile by its
    /// port and rate, or say it asks.
    func testDescriptionIsThePortAndRate() {
        let p = provider()
        XCTAssertEqual(p.description(for: Profile(type: "serial", name: "", options: ["port": "/dev/cu.a"])), "/dev/cu.a")
        XCTAssertEqual(p.description(for: Profile(type: "serial", name: "", options: ["port": "/dev/cu.a", "baudrate": 115200])),
                       "/dev/cu.a · 115200")
        XCTAssertEqual(p.description(for: Profile(type: "serial", name: "", options: [:])), "Ask every time")
        XCTAssertEqual(p.suggestedName(for: Profile(type: "serial", name: "", options: ["port": "/dev/cu.a"])), "/dev/cu.a")
        XCTAssertNil(p.suggestedName(for: Profile(type: "serial", name: "", options: [:])))
    }

    // What has to be asked before a serial tab opens (Tabby asks the baud rate in
    // `getNewTabParameters`; TabbyMac also asks the port instead of taking the first one).
    func testWhatAProfileStillNeeds() {
        XCTAssertEqual(SerialProfileProvider.missingParameters(Profile(type: "serial", name: "", options: [:])), [.port, .baudRate])
        XCTAssertEqual(SerialProfileProvider.missingParameters(Profile(type: "serial", name: "", options: ["port": "/dev/cu.a"])), [.baudRate])
        XCTAssertEqual(SerialProfileProvider.missingParameters(Profile(type: "serial", name: "", options: ["port": "/dev/cu.a", "baudrate": 9600])), [])
        XCTAssertEqual(SerialProfileProvider.missingParameters(Profile(type: "ssh", name: "", options: [:])), [])

        var p = Profile(type: "serial", name: "", options: [:])
        p = SerialProfileProvider.completing(p, port: "/dev/cu.b", baudRate: 19200)
        XCTAssertEqual(SerialOptions(p.options).port, "/dev/cu.b")
        XCTAssertEqual(SerialOptions(p.options).baudrate, 19200)
    }
}
