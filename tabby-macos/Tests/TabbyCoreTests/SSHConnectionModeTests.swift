import XCTest
@testable import TabbyCore

/// Phase 7: Tabby's SSH connection modes (`sshProfileSettings.component.ts`).
final class SSHConnectionModeTests: XCTestCase {
    func testModeFromOptions() {
        XCTAssertEqual(SSHConnectionMode(options: ["host": "h"]), .direct)
        XCTAssertEqual(SSHConnectionMode(options: ["proxyCommand": "nc %h %p", "jumpHost": "j"]), .proxyCommand, "Tabby checks the proxy command first")
        XCTAssertEqual(SSHConnectionMode(options: ["jumpHost": "ssh:custom:j:1"]), .jumpHost)
        XCTAssertEqual(SSHConnectionMode(options: ["socksProxyHost": "127.0.0.1", "socksProxyPort": 1080]), .socksProxy)
        XCTAssertEqual(SSHConnectionMode(options: ["httpProxyHost": "proxy", "httpProxyPort": 3128]), .httpProxy)
        XCTAssertEqual(SSHConnectionMode(options: ["proxyCommand": ""]), .direct, "an empty value is no mode")
    }

    func testApplyClearsTheOtherModes() {
        var options: ConfigValue = ["host": "h", "proxyCommand": "nc", "jumpHost": "j", "socksProxyHost": "s", "socksProxyPort": 1080,
                                    "httpProxyHost": "p", "httpProxyPort": 3128]
        SSHConnectionMode.socksProxy.apply(to: &options)
        XCTAssertEqual(options["socksProxyHost"]?.stringValue, "s")
        XCTAssertEqual(options["socksProxyPort"]?.intValue, 1080)
        for key in ["proxyCommand", "jumpHost", "httpProxyHost", "httpProxyPort"] { XCTAssertNil(options[key], key) }
        XCTAssertEqual(options["host"]?.stringValue, "h")
        SSHConnectionMode.direct.apply(to: &options)
        XCTAssertNil(options["socksProxyHost"])
        XCTAssertNil(options["socksProxyPort"])
    }
}
