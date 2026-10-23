#if canImport(AppKit)
import XCTest
import AppKit
import SwiftUI
import TabbyCore
@testable import TabbySSHLib
@testable import TabbyApp

/// The Ports popover's model: Tabby's form (Local 127.0.0.1:8000 → 127.0.0.1:80), live add
/// and remove, and "removing puts it back in the form" (Tabby's way to edit).
@MainActor
final class PortsPopoverTests: XCTestCase {
    final class FakeForwards {
        var list: [ForwardStatus] = []
        var failWith: String?
        var removed: [UUID] = []
    }

    func makeModel(_ fake: FakeForwards) -> PortForwardsModel {
        PortForwardsModel(
            list: { fake.list },
            add: { forward in
                if let message = fake.failWith { throw SSHConnectionError.channelFailed(message) }
                let status = ForwardStatus(id: UUID(), forward: forward)
                fake.list.append(status)
                return status.id
            },
            remove: { id in
                fake.removed.append(id)
                fake.list.removeAll { $0.id == id }
            })
    }

    func testTheFormStartsWithTabbysDefaults() {
        let model = makeModel(FakeForwards())
        XCTAssertEqual(model.type, .local)
        XCTAssertEqual(model.host, "127.0.0.1")
        XCTAssertEqual(model.port, "8000")
        XCTAssertEqual(model.targetAddress, "127.0.0.1")
        XCTAssertEqual(model.targetPort, "80")
        XCTAssertTrue(model.showsTarget)
        model.type = .dynamic
        XCTAssertFalse(model.showsTarget, "Dynamic shows SOCKS proxy instead of a target")
    }

    func testAddingAForwardListsIt() async {
        let fake = FakeForwards()
        let model = makeModel(fake)
        model.port = "15432"
        model.targetAddress = "db.internal"
        model.targetPort = "5432"
        model.descriptionText = "Postgres"
        await model.submit()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.forwards.map(\.forward), [ForwardedPort(type: .local, host: "127.0.0.1", port: 15432,
                                                                      targetAddress: "db.internal", targetPort: 5432, description: "Postgres")])
    }

    func testBadPortsAreRefusedBeforeConnecting() async {
        let fake = FakeForwards()
        let model = makeModel(fake)
        model.port = "70000"
        await model.submit()
        XCTAssertEqual(model.error, "The port must be a number from 1 to 65535.")
        XCTAssertTrue(fake.list.isEmpty)
        model.port = "8080"
        model.targetAddress = " "
        await model.submit()
        XCTAssertEqual(model.error, "Enter the address to forward to.")
    }

    func testAFailureIsShown() async {
        let fake = FakeForwards()
        fake.failWith = "Failed to forward port (local) 127.0.0.1:8000 → (remote) 127.0.0.1:80: address already in use"
        let model = makeModel(fake)
        await model.submit()
        XCTAssertEqual(model.error, fake.failWith)
        XCTAssertTrue(model.forwards.isEmpty)
    }

    func testRemovingPutsTheForwardBackInTheForm() async {
        let fake = FakeForwards()
        let existing = ForwardStatus(id: UUID(), forward: ForwardedPort(type: .remote, host: "0.0.0.0", port: 9000,
                                                                       targetAddress: "localhost", targetPort: 3000, description: "dev"))
        fake.list = [existing]
        let model = makeModel(fake)
        await model.remove(existing)
        XCTAssertEqual(fake.removed, [existing.id])
        XCTAssertTrue(model.forwards.isEmpty)
        XCTAssertEqual(model.type, .remote)
        XCTAssertEqual(model.host, "0.0.0.0")
        XCTAssertEqual(model.port, "9000")
        XCTAssertEqual(model.targetAddress, "localhost")
        XCTAssertEqual(model.targetPort, "3000")
        XCTAssertEqual(model.descriptionText, "dev")
    }
    private struct ButtonHost: View {
        let make: () -> PortForwardsModel?
        @State var isOpen = false
        var body: some View {
            PortsButton(enabled: true, makeModel: make, isOpen: $isOpen).padding(40).chromeEnvironment()
        }
    }

    /// Found in the M8 walk: the first click on Ports opened an empty popover (a 26 pt bubble).
    /// The model was set in the same action that opened it, and the popover's content was
    /// built from the state before.
    func testPortsOpensThePopoverWithTheForm() throws {
        TestApp.boot()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ButtonHost(make: { self.makeModel(FakeForwards()) }))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))
        func popover() -> NSWindow? {
            NSApp.windows.first { !before.contains(ObjectIdentifier($0)) && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        }
        defer {
            popover()?.orderOut(nil)
            window.orderOut(nil)
        }
        TestApp.pump(0.2)

        let center = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        let point = host.convert(center, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            TestApp.pump(0.05)
        }
        TestApp.pump(until: { popover() != nil }, timeout: 3)
        let shown = try XCTUnwrap(popover(), "a click on Ports opens a popover")
        TestApp.pump(until: { shown.frame.width >= 400 }, timeout: 2)
        XCTAssertGreaterThanOrEqual(shown.frame.width, 400, "the form is in it (420 pt), not an empty bubble")
    }
}
#endif
