#if canImport(AppKit)
import XCTest
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
}
#endif
