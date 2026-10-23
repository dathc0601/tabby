#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbySerial
import TabbyTerminal
@testable import TabbyApp

/// Serial profiles in the app: provider, session factory, hotkeys, and the questions asked
/// before a serial tab opens (Tabby's `getNewTabParameters` asks for the baud rate).
@MainActor
final class SerialWiringTests: XCTestCase {
    final class FakeUI: WindowModelUI {
        var asked: [(Profile, [SerialProfileProvider.Parameter])] = []
        var answer: ((Profile) -> Profile?)?
        func confirmMultilinePaste(_ text: String, completion: @escaping (Bool) -> Void) {}
        func paneDidRequestFocus(_ pane: TerminalPane) {}
        func notifyProcessEnded(_ pane: TerminalPane, code: Int32?) {}
        func modelDidBecomeEmpty() {}
        func completeSerialProfile(_ profile: Profile, missing: [SerialProfileProvider.Parameter],
                                   completion: @escaping (Profile?) -> Void) {
            asked.append((profile, missing))
            completion(answer?(profile))
        }
    }

    private func dispose(_ model: WindowModel) {
        for tab in model.tabs { for pane in tab.orderedPanes { pane.close() } }
    }

    func testSerialIsWiredIn() async throws {
        TestApp.boot()
        let services = AppServices.shared
        XCTAssertTrue(services.factories["serial"] is SerialSessionFactory)
        XCTAssertTrue(services.profiles.provider(for: "serial") is SerialProfileProvider)
        XCTAssertTrue(services.profiles.allProfiles().contains { $0.id == "serial:template" })
        XCTAssertEqual(services.config.value("hotkeys.serial")?.stringArrayValue, ["⌥-K"])
        XCTAssertEqual(services.config.value("hotkeys.restart-serial-session")?.arrayValue?.count, 0)
        XCTAssertNotNil(HotkeyCatalog.byId["serial"])
        XCTAssertNotNil(HotkeyCatalog.byId["restart-serial-session"])
    }

    func testOpeningATemplateAsksForThePortAndRateForThisTabOnly() async throws {
        TestApp.boot()
        let services = AppServices.shared
        let model = WindowModel()
        let ui = FakeUI()
        model.ui = ui
        defer { dispose(model) }
        ui.answer = { SerialProfileProvider.completing($0, port: "/dev/cu.tabbymac-test-none", baudRate: 9600) }
        let template = try XCTUnwrap(services.profiles.profile(withId: "serial:template"))
        model.openTab(profile: template)
        XCTAssertEqual(ui.asked.map(\.1), [[.port, .baudRate]])
        let pane = try XCTUnwrap(model.activePane)
        XCTAssertEqual(SerialOptions(pane.profile.options).port, "/dev/cu.tabbymac-test-none")
        XCTAssertEqual(SerialOptions(pane.recoveryState().profile.options).baudrate, 9600, "the recovery token keeps the answers")
        XCTAssertFalse(services.profiles.userProfiles.contains { $0.type == "serial" }, "config is not changed")
    }

    func testCancellingOpensNothing() async throws {
        TestApp.boot()
        let model = WindowModel()
        let ui = FakeUI()
        model.ui = ui
        model.openTab(profile: Profile(type: "serial", name: "s", options: ["port": "/dev/cu.tabbymac-test-none"]))
        XCTAssertEqual(ui.asked.map(\.1), [[.baudRate]])
        XCTAssertTrue(model.tabs.isEmpty)
    }

    func testAProfileWithPortAndRateOpensWithoutQuestions() async throws {
        TestApp.boot()
        let model = WindowModel()
        let ui = FakeUI()
        model.ui = ui
        defer { dispose(model) }
        model.openTab(profile: Profile(type: "serial", name: "s", options: ["port": "/dev/cu.tabbymac-test-none", "baudrate": 115200]))
        XCTAssertTrue(ui.asked.isEmpty)
        XCTAssertEqual(model.tabs.count, 1)
    }

    func testSwitchingAPaneToASerialProfileAsksToo() async throws {
        TestApp.boot()
        let model = WindowModel()
        let ui = FakeUI()
        model.ui = ui
        defer { dispose(model) }
        model.openTab(profile: TestApp.profile("sh", "sleep 5"))
        ui.answer = { SerialProfileProvider.completing($0, baudRate: 300) }
        model.switchActivePane(to: Profile(type: "serial", name: "s", options: ["port": "/dev/cu.tabbymac-test-none"]))
        XCTAssertEqual(ui.asked.map(\.1), [[.baudRate]])
        XCTAssertEqual(SerialOptions(try XCTUnwrap(model.activePane).profile.options).baudrate, 300)
    }

    func testRestoringASerialTabNeverAsks() async throws {
        TestApp.boot()
        let model = WindowModel()
        let ui = FakeUI()
        model.ui = ui
        defer { dispose(model) }
        let profile = Profile(id: "serial:template", type: "serial", name: "Serial connection")
        model.restore(.pane(PaneRecovery(type: "app:serial-tab", profile: profile)))
        XCTAssertTrue(ui.asked.isEmpty)
        XCTAssertEqual(model.tabs.count, 1)
    }
}
#endif
