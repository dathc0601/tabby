#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbySerial
import TabbyTerminal
import TabbyTestSupport
@testable import TabbyApp

/// The places in the UI that used to assume "not local means SSH" now know serial and telnet.
@MainActor
final class ConnectionTypesUITests: XCTestCase {
    func testEditorPagesPerType() {
        XCTAssertEqual(ProfileEditorSheet.pages(for: "ssh"), ProfileEditorSheet.Page.allCases)
        for type in ["serial", "telnet", "local"] {
            XCTAssertEqual(ProfileEditorSheet.pages(for: type), [.general, .advanced, .colors, .scripts], type)
        }
    }

    func testEveryTypeCanBeCreated() {
        XCTAssertEqual(ProfileTypes.creatable, ["local", "ssh", "serial", "telnet"])
        XCTAssertEqual(ProfileTypes.creatable.map(ProfileTypes.title), ["Local terminal", "SSH connection", "Serial connection", "Telnet connection"])
        let telnet = ProfileTypes.newProfile("telnet")
        XCTAssertEqual(telnet.type, "telnet")
        XCTAssertEqual(TelnetOptions(telnet.options).port, 23)
        XCTAssertFalse(telnet.clearServiceMessagesOnConnect)
        let serial = ProfileTypes.newProfile("serial")
        XCTAssertEqual(serial.type, "serial")
        XCTAssertNil(SerialOptions(serial.options).baudrate, "ask every time")
        XCTAssertEqual(ProfileTypes.newProfile("ssh").options["port"], 22)
    }

    func testAnUnnamedProfileIsNamedByItsProvider() {
        TestApp.boot()
        XCTAssertEqual(ProfileEditorSheet.named(Profile(type: "telnet", name: "", options: ["host": "r", "port": 23])).name, "r:23")
        XCTAssertEqual(ProfileEditorSheet.named(Profile(type: "serial", name: "", options: ["port": "/dev/cu.a"])).name, "/dev/cu.a")
        XCTAssertEqual(ProfileEditorSheet.named(Profile(type: "ssh", name: "", options: ["host": "h", "user": "me"])).name, "me@h:22", "as before")
        XCTAssertEqual(ProfileEditorSheet.named(Profile(type: "telnet", name: "Router", options: ["host": "r"])).name, "Router")
    }

    // Review: "Normal" and "Keep" were stored as null and then dropped, so Tabby's telnet
    // defaults (local echo, CRLF) came back; the pickers showed Normal/Keep regardless.
    func testTheEditorShowsAndSavesNormalAndKeep() {
        TestApp.boot()
        var p = ProfileTypes.newProfile("telnet")
        p.options["host"] = "h"
        XCTAssertEqual(ProfileEditorSheet.effectiveOption(p, "inputMode"), "local-echo", "shows what runs")
        XCTAssertEqual(ProfileEditorSheet.effectiveOption(p, "outputNewlines"), "crlf")
        p.options["inputMode"] = .null       // the pickers' "Normal"
        p.options["outputNewlines"] = .null  // and "Keep"
        p.options["cwd"] = .null             // an ordinary empty value
        XCTAssertEqual(ProfileEditorSheet.effectiveOption(p, "inputMode"), "")
        let saved = ProfileEditorSheet.finalized(p)
        XCTAssertNil(saved.options["cwd"], "empty values still go")
        let resolved = AppServices.shared.profiles.resolved(Profile(config: saved.configValue))
        XCTAssertNil(StreamOptions(resolved.options).inputMode)
        XCTAssertNil(StreamOptions(resolved.options).outputNewlines)
    }

    /// Design C6a: the editor's Device menu lists external ports with Tabby's description, then
    /// the Mac's own ports after a separator.
    func testTheDeviceMenuListsExternalPortsThenBuiltInOnes() {
        let ports = [SerialPortInfo(path: "/dev/cu.debug-console"),
                     SerialPortInfo(path: "/dev/cu.usbserial-1420", description: "FTDI FT3K2PQ1"),
                     SerialPortInfo(path: "/dev/cu.usbmodem2101")]
        XCTAssertEqual(ProfileEditorSheet.deviceMenu(ports: ports), [
            .port(title: "cu.usbserial-1420 (FTDI FT3K2PQ1)", path: "/dev/cu.usbserial-1420"),
            .port(title: "cu.usbmodem2101", path: "/dev/cu.usbmodem2101"),
            .separator,
            .port(title: "cu.debug-console", path: "/dev/cu.debug-console"),
        ])
        XCTAssertEqual(ProfileEditorSheet.deviceMenu(ports: [SerialPortInfo(path: "/dev/cu.debug-console")]),
                       [.port(title: "cu.debug-console", path: "/dev/cu.debug-console")], "no separator without external ports")
        XCTAssertEqual(ProfileEditorSheet.deviceMenu(ports: []), [])
    }

    func testDefaultIconsPerType() {
        XCTAssertEqual(ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: "serial")), "cable.connector")
        XCTAssertEqual(ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: "telnet")), "network")
        XCTAssertEqual(ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: "ssh")), "server.rack")
        XCTAssertEqual(ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: "local")), "terminal")
        XCTAssertEqual(ProfileIcons.symbol(for: "fas fa-microchip"), "cable.connector")
        XCTAssertEqual(ProfileIcons.symbol(for: "fas fa-network-wired"), "network")
        for type in ["local", "ssh", "serial", "telnet"] {
            let symbol = ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: type))
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), "\(symbol) exists on macOS 14")
        }
    }

    /// Design C1b: a tab shows its type's icon when the profile names none.
    func testATabShowsItsTypesIconWhenTheProfileHasNone() throws {
        TestApp.boot()
        let model = WindowModel()
        let tab = try XCTUnwrap(model.openTab(profile: Profile(type: "telnet", name: "t", options: ["host": "127.0.0.1", "port": 1])))
        defer { for pane in tab.orderedPanes { pane.close() } }
        XCTAssertEqual(tab.icon, "fas fa-network-wired")
    }

    func testStartPageSubtitles() {
        TestApp.boot()
        XCTAssertEqual(StartPageView.subtitle(of: Profile(type: "serial", name: "s", options: ["port": "/dev/cu.a"])), "/dev/cu.a")
        XCTAssertEqual(StartPageView.subtitle(of: Profile(type: "telnet", name: "t", options: ["host": "h", "port": 2323])), "h:2323")
        XCTAssertEqual(StartPageView.subtitle(of: Profile(type: "ssh", name: "s", options: ["host": "h", "user": "me"])), "me@h")
        XCTAssertEqual(StartPageView.subtitle(of: Profile(type: "local", name: "l", options: ["command": "/bin/zsh"])), "/bin/zsh")
    }

    func testQuickConnectCanUseEveryProvider() {
        TestApp.boot()
        XCTAssertEqual(ProfileTypes.quickConnectProviders.map(\.id), ["ssh", "serial", "telnet"])
    }

    // The chip's "Baud rate": applied to the open port, kept by the tab and its recovery token.
    func testChangingTheBaudRateOfAnOpenPort() async throws {
        TestApp.boot()
        let pty = try PTYPair()
        let model = WindowModel()
        defer { for tab in model.tabs { for pane in tab.orderedPanes { pane.close() } } }
        model.openTab(profile: Profile(type: "serial", name: "s", options: ["port": .string(pty.replicaPath), "baudrate": 9600]))
        let pane = try XCTUnwrap(model.activePane)
        pane.start()
        XCTAssertEqual(SerialChip.serialSession(of: pane)?.baudRate, 9600)
        try SerialChip.changeBaudRate(of: pane, to: 57600)
        XCTAssertEqual(SerialChip.serialSession(of: pane)?.baudRate, 57600)
        XCTAssertEqual(SerialOptions(pane.profile.options).baudrate, 57600)
        XCTAssertEqual(SerialOptions(pane.recoveryState().profile.options).baudrate, 57600)
        let probe = open(pty.replicaPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        defer { close(probe) }
        var t = termios()
        XCTAssertEqual(tcgetattr(probe, &t), 0)
        XCTAssertEqual(cfgetospeed(&t), speed_t(57600))
    }
}
#endif
