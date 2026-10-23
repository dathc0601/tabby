#if os(macOS)
import XCTest
import TabbyCore
import TabbyTestSupport
@testable import TabbySerial

/// The list of serial ports and its hot-plug updates, over a fake registry.
final class SerialPortListTests: XCTestCase {
    final class FakeRegistry: SerialRegistry {
        var ports: [SerialPortInfo] = []
        var changed: (() -> Void)?
        func currentPorts() -> [SerialPortInfo] { ports }
        func watch(_ changed: @escaping () -> Void) -> AnyObject? {
            self.changed = changed
            return NSObject()
        }
    }

    func testPortsAreListedExternalFirstThenByPath() {
        let registry = FakeRegistry()
        registry.ports = [
            SerialPortInfo(path: "/dev/cu.debug-console"),
            SerialPortInfo(path: "/dev/cu.usbserial-B"),
            SerialPortInfo(path: "/dev/cu.Bluetooth-Incoming-Port"),
            SerialPortInfo(path: "/dev/cu.usbserial-A", description: "FTDI 1"),
        ]
        let list = SerialPortList(registry: registry)
        XCTAssertEqual(list.ports.map(\.deviceName),
                       ["cu.usbserial-A", "cu.usbserial-B", "cu.Bluetooth-Incoming-Port", "cu.debug-console"])
    }

    func testPluggingInAPortUpdatesTheListAndTellsObservers() {
        let registry = FakeRegistry()
        let list = SerialPortList(registry: registry)
        var notified = 0
        let token = list.observe { notified += 1 }
        XCTAssertEqual(list.ports, [])
        registry.ports = [SerialPortInfo(path: "/dev/cu.usbmodem1")]
        registry.changed?()
        XCTAssertEqual(list.ports.map(\.path), ["/dev/cu.usbmodem1"])
        XCTAssertEqual(notified, 1)
        registry.changed?()
        XCTAssertEqual(notified, 1, "no news, no notification")
        withExtendedLifetime(token) {}
    }

    func testAnObserverStopsWhenItsTokenGoes() {
        let registry = FakeRegistry()
        let list = SerialPortList(registry: registry)
        var notified = 0
        var token: AnyObject? = list.observe { notified += 1 }
        XCTAssertNotNil(token)
        token = nil
        registry.ports = [SerialPortInfo(path: "/dev/cu.usbmodem1")]
        registry.changed?()
        XCTAssertEqual(notified, 0)
    }

    // The real registry on this Mac: listing only, nothing is opened.
    func testTheSystemRegistryListsCalloutDevices() {
        let ports = IOKitSerialRegistry().currentPorts()
        for port in ports {
            XCTAssertTrue(port.path.hasPrefix("/dev/cu."), port.path)
        }
        let token = IOKitSerialRegistry().watch {}
        XCTAssertNotNil(token)
    }
}
#endif
