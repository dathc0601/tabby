#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: the local shell's environment and command line, and port forward descriptions.
@MainActor
final class ProfileEditorFieldsTests: XCTestCase {
    func testEnvironmentRowsWriteTheEnv() {
        var rows = EnvironmentRows(env: ["FOO": "1", "BAR": "two"])
        XCTAssertEqual(rows.rows.map(\.name), ["BAR", "FOO"], "sorted by name, as stored")
        rows.add()
        rows.rows[2].name = "NEW"
        rows.rows[2].value = "x"
        rows.remove(at: 0)
        XCTAssertEqual(rows.env, ["FOO": "1", "NEW": "x"])
        rows.add()
        XCTAssertEqual(rows.env, ["FOO": "1", "NEW": "x"], "a row without a name isn't written")
        XCTAssertNil(EnvironmentRows(env: nil).env, "no variables, no key")
    }

    func testExtendPathExample() {
        var rows = EnvironmentRows(env: nil)
        XCTAssertTrue(rows.showsExample)
        rows.addExample()
        XCTAssertEqual(rows.env, ["PATH": "/opt/custom:$PATH"])
        XCTAssertFalse(rows.showsExample, "only while there is no PATH")
    }

    func testCommandLineRoundTrip() {
        let split = CommandLineField.split("/bin/zsh -l -c 'echo hi'")
        XCTAssertEqual(split.command, "/bin/zsh")
        XCTAssertEqual(split.args, ["-l", "-c", "echo hi"])
        XCTAssertEqual(CommandLineField.join(command: "/bin/zsh", args: ["-l", "-c", "echo hi"]), "/bin/zsh -l -c 'echo hi'")
        XCTAssertEqual(CommandLineField.split("").command, "")
    }

    func testPortForwardDescriptionIsWritten() {
        let options: ConfigValue = ["forwardedPorts": [ForwardedPort(type: .local, port: 8080, targetAddress: "localhost", targetPort: 80).configValue]]
        let updated = PortForwardsEditor.updated(options, 0, \.description, "web")
        XCTAssertEqual(updated["forwardedPorts"]?.arrayValue?.first?["description"]?.stringValue, "web")
    }
}
#endif
