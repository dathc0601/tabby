#if canImport(AppKit)
import XCTest
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Phase 7: the Profiles page — group deletion, hiding, Advanced, icons and colours, the tree
/// rows and what a defaults editor writes. Each test has its own registry.
@MainActor
final class ProfilesPageTests: XCTestCase {
    func registry(_ user: ConfigValue) throws -> ProfileRegistry {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: user)
        let shells = [Shell(id: "default", name: "OS default (zsh)", command: "/bin/zsh", args: ["--login"])]
        return ProfileRegistry(config: store, providers: [LocalProfileProvider(shells: { shells }), SSHProfileProvider(sshConfig: { "" })],
                               recents: RecentProfilesStore(url: nil))
    }

    override func tearDown() {
        ProfileGroupActions.ask = ProfileGroupActions.defaultAsk
        super.tearDown()
    }

    func work() throws -> ProfileRegistry {
        try registry(["groups": [["id": "W", "name": "Work"]],
                      "profiles": [["id": "p1", "name": "one", "type": "ssh", "group": "W", "options": ["host": "h"]]]])
    }

    /// Answers the questions in order and records them.
    func answer(_ answers: [Int]) -> () -> [(String, [String])] {
        var asked: [(String, [String])] = []
        var queue = answers
        ProfileGroupActions.ask = { message, buttons, reply in
            asked.append((message, buttons))
            reply(queue.isEmpty ? 1 : queue.removeFirst())
        }
        return { asked }
    }

    func testGroupDeletionAsksTwiceWithTabbysWords() throws {
        let r = try work()
        let asked = answer([0, 0])
        ProfileGroupActions.delete(try XCTUnwrap(r.groups.first), registry: r)
        XCTAssertEqual(asked().map(\.0), ["Delete \"Work\"?", "Delete the group's profiles?"])
        XCTAssertEqual(asked().map(\.1), [["Delete", "Keep"], ["Move to \"Ungrouped\"", "Delete"]])
        XCTAssertTrue(r.groups.isEmpty)
        XCTAssertNil(r.userProfiles.first?.group, "moved to Ungrouped")

        let r2 = try work()
        _ = answer([0, 1])
        ProfileGroupActions.delete(try XCTUnwrap(r2.groups.first), registry: r2)
        XCTAssertTrue(r2.userProfiles.isEmpty, "deleted with the group")

        let r3 = try work()
        _ = answer([1])
        ProfileGroupActions.delete(try XCTUnwrap(r3.groups.first), registry: r3)
        XCTAssertEqual(r3.groups.count, 1, "Keep keeps it")
    }

    func testDeletingAnEmptyGroupAsksOnce() throws {
        let r = try registry(["groups": [["id": "E", "name": "Empty"]]])
        let asked = answer([0])
        ProfileGroupActions.delete(try XCTUnwrap(r.groups.first), registry: r)
        XCTAssertEqual(asked().count, 1)
        XCTAssertTrue(r.groups.isEmpty)
    }

    func testResettingTypeDefaultsAsksFirst() throws {
        let r = try registry(["profileDefaults": ["ssh": ["options": ["port": 2200]]]])
        let asked = answer([1])
        ProfileGroupActions.resetTypeDefaults("ssh", registry: r)
        XCTAssertEqual(asked().first?.0, "Restore settings to defaults ?")
        XCTAssertEqual(r.typeDefaults("ssh")["options"]?["port"]?.intValue, 2200, "Keep")
        _ = answer([0])
        ProfileGroupActions.resetTypeDefaults("ssh", registry: r)
        XCTAssertNil(r.typeDefaults("ssh")["options"])
    }

    func testHideAndShowUseTheBlacklist() throws {
        let r = try work()
        let builtin = try XCTUnwrap(r.profile(withId: "local:default"))
        ProfilesSettingsView.toggleHidden(builtin, registry: r)
        XCTAssertEqual(r.config.value("profileBlacklist")?.stringArrayValue, ["local:default"])
        ProfilesSettingsView.toggleHidden(builtin, registry: r)
        XCTAssertEqual(r.config.value("profileBlacklist")?.stringArrayValue ?? [], [])
    }

    func testAdvancedRowsShowOnlyWithCustomProfiles() throws {
        XCTAssertFalse(ProfilesSettingsView.showsAdvanced(registry: try registry([:])))
        XCTAssertTrue(ProfilesSettingsView.showsAdvanced(registry: try work()))
    }

    func testRowsFollowTheTreeAndCollapse() throws {
        let r = try registry(["groups": [["id": "A", "name": "A"], ["id": "B", "name": "B", "parentGroupId": "A"]],
                              "profiles": [["id": "p1", "name": "one", "type": "ssh", "group": "A", "options": ["host": "h"]],
                                           ["id": "p2", "name": "two", "type": "ssh", "group": "B", "options": ["host": "h"]]]])
        let tree = r.tree(r.allProfiles(includeBuiltin: false))
        func ids(_ rows: [ProfilesSettingsView.Row]) -> [String] { rows.map(\.id) }
        XCTAssertEqual(ids(ProfilesSettingsView.rows(tree, collapsed: [])), ["g:A", "p:p1", "g:B", "p:p2"])
        XCTAssertEqual(ids(ProfilesSettingsView.rows(tree, collapsed: ["A"])), ["g:A"], "a collapsed group hides its subgroups too")
        guard case let .group(_, depth) = ProfilesSettingsView.rows(tree, collapsed: [])[2] else { return XCTFail("B") }
        XCTAssertEqual(depth, 1)
        let filtered = r.tree([try XCTUnwrap(r.profile(withId: "p2"))])
        XCTAssertEqual(ids(ProfilesSettingsView.rows(filtered, collapsed: [], dropEmpty: true)), ["g:A", "g:B", "p:p2"],
                       "while filtering, a parent stays for a match below it")
    }

    func testIconCatalogMapsTabbyNames() {
        XCTAssertEqual(ProfileIcons.symbol(for: "fas fa-server"), "server.rack")
        XCTAssertEqual(ProfileIcons.symbol(for: "far fa-folder"), "folder")
        XCTAssertEqual(ProfileIcons.symbol(for: "fa-solid fa-key fa-fw"), "key")
        XCTAssertEqual(ProfileIcons.symbol(for: "server"), "server.rack", "bare names of earlier builds")
        XCTAssertEqual(ProfileIcons.symbol(for: "fas fa-dragon"), "terminal")
        XCTAssertFalse(ProfileIcons.isKnown("fas fa-dragon"))
        XCTAssertEqual(ProfileIcons.className("server"), "fas fa-server")
        let missing = ProfileIcons.catalog.filter { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) == nil }
        XCTAssertEqual(missing.map(\.symbol), [], "every symbol exists on this macOS")
        XCTAssertGreaterThanOrEqual(ProfileIcons.catalog.count, 100)
    }

    func testColoursOfTabbyAndCSSNames() {
        XCTAssertEqual(ProfileColors.named.map(\.value), ["#0275d8", "#5cb85c", "#f0ad4e", "#613d7c", "#d9534f", "#ffd500"])
        XCTAssertEqual(ProfileColors.rgb("teal")?.hex, "#008080")
        XCTAssertEqual(ProfileColors.rgb("#0275d8")?.hex, "#0275d8")
        XCTAssertNil(ProfileColors.rgb("not a colour"))
    }

    func testClearedDefaultsFieldsAreRemoved() {
        var p = ProfileEditorSheet.profile(fromDefaults: ["options": ["port": 2200, "user": "root"]], type: "ssh")
        p.options["port"] = .string("")
        p.options["algorithms"] = .object(["cipher": .array([])])
        let value = ProfileEditorSheet.defaultsValue(from: p)
        XCTAssertEqual(value["options"]?["user"]?.stringValue, "root")
        XCTAssertNil(value["options"]?["port"], "an emptied field doesn't override the inherited value")
        XCTAssertNil(value["options"]?["algorithms"])
        XCTAssertNil(value["name"])
        XCTAssertNil(value["behaviorOnSessionEnd"], "auto is the default")
    }
}
#endif
