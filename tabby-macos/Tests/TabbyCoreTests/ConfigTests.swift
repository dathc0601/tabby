import XCTest
@testable import TabbyCore

final class ConfigTests: XCTestCase {
    func makeStore(user: ConfigValue = .emptyObject) throws -> ConfigStore {
        ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: user)
    }

    func fixture() throws -> ConfigValue {
        let url = Bundle.module.url(forResource: "Fixtures/tabby-config", withExtension: "yaml")!
        return try YAMLCoding.parse(String(contentsOf: url, encoding: .utf8))
    }

    func testDefaultsLoad() throws {
        let store = try makeStore()
        XCTAssertEqual(store.int("terminal.fontSize"), 14)
        XCTAssertEqual(store.string("terminal.font"), "Menlo")
        XCTAssertEqual(store.string("appearance.dock"), "off", "quoted 'off' must stay a string")
        XCTAssertEqual(store.string("appearance.frame"), "thin")
        XCTAssertEqual(store.value("hotkeys.new-tab")?.stringArrayValue, ["⌘-T"])
        XCTAssertEqual(store.value("terminal.colorScheme")?["name"]?.stringValue, "Tabby Default")
        XCTAssertNil(store.value("terminal.colorScheme")?[ConfigValue.nonStructuralKey], "markers are stripped")
    }

    func testFreshStoreSerializesAlmostNothing() throws {
        let store = try makeStore()
        XCTAssertEqual(store.user, ["version": .int(Migrations.latestVersion)])
    }

    func testSettingDefaultRemovesKey() throws {
        let store = try makeStore()
        store.set("terminal.fontSize", 18)
        XCTAssertEqual(store.user.value(at: "terminal.fontSize"), 18)
        store.set("terminal.fontSize", 14)
        XCTAssertNil(store.user["terminal"], "setting back to default prunes the empty mapping")
    }

    func testNonStructualLeafReplacedWholesale() throws {
        let store = try makeStore(user: try fixture())
        let scheme = store.value("terminal.colorScheme")
        XCTAssertEqual(scheme?["name"]?.stringValue, "Dracula")
        XCTAssertEqual(scheme?["colors"]?.arrayValue?.count, 16)
        // profileDefaults is non-structural: the user's mapping replaces the default `ssh.disableDynamicTitle`.
        XCTAssertNil(store.value("profileDefaults.ssh.disableDynamicTitle"))
        XCTAssertEqual(store.value("profileDefaults.ssh.options.x11"), true)
    }

    func testStructuralMerge() throws {
        let store = try makeStore(user: try fixture())
        XCTAssertEqual(store.int("terminal.fontSize"), 16)
        XCTAssertEqual(store.string("terminal.cursor"), "block", "unspecified keys fall back to defaults")
        XCTAssertEqual(store.string("appearance.dock"), "top")
        XCTAssertEqual(store.value("hotkeys.split-right")?.stringArrayValue, ["⌘-Shift-X"])
        XCTAssertEqual(store.value("hotkeys.split-bottom")?.stringArrayValue, ["⌘-D"])
        XCTAssertEqual(store.value("someUnknownPluginKey.nested"), "value")
    }

    func testWriteBelowLeaf() throws {
        let store = try makeStore()
        store.set("hotkeys.profile.my-profile", ["⌘-1"])
        XCTAssertEqual(store.value("hotkeys.profile.my-profile")?.stringArrayValue, ["⌘-1"])
        XCTAssertEqual(store.user.value(at: "hotkeys.profile")?.objectValue?.count, 1)
    }

    func testRoundTripPreservesUnknownKeys() throws {
        let store = try makeStore(user: try fixture())
        let yaml = try store.serializedUserConfig()
        let reloaded = try YAMLCoding.parse(yaml)
        XCTAssertEqual(reloaded, store.user)
        XCTAssertTrue(yaml.contains("someUnknownPluginKey"))
    }

    func testYAMLQuotesAmbiguousStrings() throws {
        let yaml = try YAMLCoding.serialize(["a": "off", "b": "123", "c": "yes", "d": "plain", "e": .null, "f": true])
        let back = try YAMLCoding.parse(yaml)
        XCTAssertEqual(back["a"], "off")
        XCTAssertEqual(back["b"], "123")
        XCTAssertEqual(back["c"], "yes")
        XCTAssertEqual(back["d"], "plain")
        XCTAssertEqual(back["e"], .null)
        XCTAssertEqual(back["f"], true)
        XCTAssertTrue(yaml.contains("'off'"), yaml)
    }

    func testMigrationFromV0() throws {
        var legacy: ConfigValue = [
            "terminal": ["recoverTabs": false, "profiles": [["name": "zsh", "sessionOptions": ["command": "/bin/zsh"]]]],
            "ssh": ["connections": [
                ["name": "box", "host": "box.local", "privateKey": "/k", "group": "Home"],
                ["name": "inner", "host": "inner.local", "jumpHost": "box"],
            ]],
        ]
        Migrations.migrate(&legacy)
        XCTAssertEqual(legacy["version"], .int(Migrations.latestVersion))
        XCTAssertEqual(legacy["recoverTabs"], false)
        let profiles = legacy["profiles"]?.arrayValue ?? []
        XCTAssertEqual(profiles.count, 3)
        let box = profiles.first { $0["name"] == "box" }
        XCTAssertEqual(box?.value(at: "options.privateKeys")?.stringArrayValue, ["/k"])
        let inner = profiles.first { $0["name"] == "inner" }
        XCTAssertEqual(inner?.value(at: "options.jumpHost")?.stringValue, box?["id"]?.stringValue)
        let groups = legacy["groups"]?.arrayValue ?? []
        XCTAssertEqual(groups.first?["name"], "Home")
        XCTAssertEqual(box?["group"]?.stringValue, groups.first?["id"]?.stringValue)
        XCTAssertTrue(profiles.allSatisfy { !($0["id"]?.stringValue ?? "").isEmpty })
    }
}
