import XCTest
@testable import TabbyCore

/// `telnet` profiles: Tabby's `TelnetProfilesService` (`tabby-telnet/src/profiles.ts`).
final class TelnetProfileTests: XCTestCase {
    let provider = TelnetProfileProvider()

    func testTheTwoTemplates() {
        let builtins = provider.builtinProfiles()
        XCTAssertEqual(builtins.map(\.id), ["telnet:template", "socket:template"])
        XCTAssertEqual(builtins.map(\.name), ["Telnet session", "Raw socket connection"])
        XCTAssertTrue(builtins.allSatisfy { $0.type == "telnet" && $0.isTemplate && $0.isBuiltin })
        XCTAssertTrue(builtins.allSatisfy { $0.icon == "fas fa-network-wired" })
        XCTAssertEqual(TelnetOptions(builtins[0].options).port, 23)
        XCTAssertEqual(StreamOptions(builtins[0].options).inputMode, .readline)
        XCTAssertEqual(StreamOptions(builtins[0].options).outputNewlines, .crlf)
        XCTAssertEqual(TelnetOptions(builtins[1].options).port, 1234)
    }

    func testDefaultsAreTabbys() throws {
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        let registry = ProfileRegistry(config: config, providers: [provider], recents: RecentProfilesStore(url: nil))
        let resolved = registry.resolved(Profile(id: "telnet:x", type: "telnet", name: "", options: ["host": "router"]))
        let options = TelnetOptions(resolved.options)
        XCTAssertEqual(options.host, "router")
        XCTAssertEqual(options.port, 23)
        XCTAssertEqual(StreamOptions(resolved.options).inputMode, .localEcho)
        XCTAssertEqual(StreamOptions(resolved.options).outputNewlines, .crlf)
        XCTAssertEqual(InputProcessing.backspaceMode(resolved.options), "backspace")
        XCTAssertFalse(resolved.clearServiceMessagesOnConnect)
        XCTAssertEqual(resolved.name, "router:23", "the suggested name is the description")
    }

    func testQuickConnect() throws {
        let p = try XCTUnwrap(provider.quickConnect("switch.lan"))
        XCTAssertEqual(p.type, "telnet")
        XCTAssertEqual(p.name, "switch.lan")
        XCTAssertEqual(TelnetOptions(p.options).host, "switch.lan")
        XCTAssertEqual(TelnetOptions(p.options).port, 23)
        XCTAssertEqual(StreamOptions(p.options).inputMode, .readline)
        XCTAssertEqual(StreamOptions(p.options).outputNewlines, .crlf)

        XCTAssertEqual(TelnetOptions(try XCTUnwrap(provider.quickConnect("10.0.0.1:2323")).options).port, 2323)
        let v6 = TelnetOptions(try XCTUnwrap(provider.quickConnect("[::1]:2323")).options)
        XCTAssertEqual(v6.host, "::1")
        XCTAssertEqual(v6.port, 2323)
        XCTAssertEqual(TelnetOptions(try XCTUnwrap(provider.quickConnect("[fe80::1]")).options).port, 23)
        XCTAssertNil(provider.quickConnect("  "))
        XCTAssertNil(provider.quickConnect("host:notaport"))
    }

    func testQuickConnectStringRoundTrips() throws {
        for query in ["switch.lan", "10.0.0.1:2323", "[::1]:2323", "[fe80::1]"] {
            let profile = try XCTUnwrap(provider.quickConnect(query))
            XCTAssertEqual(TelnetProfileProvider.quickConnectString(TelnetOptions(profile.options)), query)
        }
    }

    func testDescription() {
        XCTAssertEqual(provider.description(for: Profile(type: "telnet", name: "", options: ["host": "h", "port": 2323])), "h:2323")
        XCTAssertEqual(provider.description(for: Profile(type: "telnet", name: "", options: ["host": ""])), "")
        XCTAssertNil(provider.suggestedName(for: Profile(type: "telnet", name: "", options: [:])))
    }
}
