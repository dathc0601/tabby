import XCTest
@testable import TabbyCore

/// Phase 7: the profile tree, group deletion, Tabby's blacklist, type defaults and selector
/// filters (Tabby's `ProfilesService` and `profilesSettingsTab`).
final class ProfileTreeTests: XCTestCase {
    func registry(_ user: ConfigValue) throws -> ProfileRegistry {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: user)
        let shells = [Shell(id: "default", name: "OS default (zsh)", command: "/bin/zsh", args: ["--login"])]
        return ProfileRegistry(config: store,
                               providers: [LocalProfileProvider(shells: { shells }), SSHProfileProvider(sshConfig: { "" })],
                               recents: RecentProfilesStore(url: nil))
    }

    func group(_ id: String, _ name: String, parent: String? = nil, defaults: ConfigValue? = nil) -> ConfigValue {
        var o: [String: ConfigValue] = ["id": .string(id), "name": .string(name)]
        if let parent { o["parentGroupId"] = .string(parent) }
        if let defaults { o["defaults"] = defaults }
        return .object(o)
    }

    func profile(_ id: String, _ name: String, type: String = "ssh", group: String? = nil, options: ConfigValue = ["host": "h"]) -> ConfigValue {
        var o: [String: ConfigValue] = ["id": .string(id), "name": .string(name), "type": .string(type), "options": options]
        if let group { o["group"] = .string(group) }
        return .object(o)
    }

    func testGroupsNestUnderTheirParent() throws {
        let r = try registry(["groups": [group("A", "A"), group("B", "B", parent: "A")],
                              "profiles": [profile("p1", "one", group: "A"), profile("p2", "two", group: "B"), profile("p3", "three")]])
        let roots = r.tree(r.allProfiles(includeBuiltin: false))
        XCTAssertEqual(roots.map(\.name), ["A", "Ungrouped"])
        XCTAssertEqual(roots[0].children.map { $0.group?.name }, ["B"])
        XCTAssertEqual(roots[0].profiles.map(\.id), ["p1"])
        XCTAssertEqual(roots[0].children[0].profiles.map(\.id), ["p2"])
        XCTAssertEqual(roots[1].profiles.map(\.id), ["p3"])
        XCTAssertNil(roots[1].group)
    }

    func testCyclesAndMissingParentsStillShowEverything() throws {
        let r = try registry(["groups": [group("A", "A", parent: "B"), group("B", "B", parent: "A"), group("C", "C", parent: "gone")]])
        // Set after loading: on load, Tabby's migration turns an unknown group name into a group.
        r.config.set("profiles", [profile("p1", "one", group: "A"), profile("p2", "two", group: "nowhere")])
        func all(_ nodes: [ProfileTreeNode]) -> [ProfileTreeNode] { nodes.flatMap { [$0] + all($0.children) } }
        let nodes = all(r.tree(r.allProfiles(includeBuiltin: false)))
        XCTAssertEqual(nodes.compactMap { $0.group?.id }.sorted(), ["A", "B", "C"], "every group once")
        XCTAssertEqual(nodes.flatMap(\.profiles).map(\.id).sorted(), ["p1", "p2"], "every profile once")
        XCTAssertEqual(nodes.first { $0.group == nil }?.profiles.map(\.id), ["p2"], "a missing group means Ungrouped")
    }

    func testBuiltinProfilesFormTheirOwnNodesAfterTheUserGroups() throws {
        let r = try registry(["groups": [group("A", "A")], "profiles": [profile("p1", "one", group: "A")]])
        let roots = r.tree(r.allProfiles())
        XCTAssertEqual(roots.first?.name, "A")
        let builtin = try XCTUnwrap(roots.last)
        XCTAssertTrue(builtin.profiles.allSatisfy(\.isBuiltin))
        XCTAssertEqual(builtin.group?.editable, false)
    }

    func testValidParentsExcludeSelfAndDescendants() throws {
        let r = try registry(["groups": [group("A", "A"), group("B", "B", parent: "A"), group("C", "C", parent: "B"), group("D", "D")]])
        XCTAssertEqual(r.validParents(for: "A").map(\.id), ["D"])
        XCTAssertEqual(r.descendants(of: "A"), ["B", "C"])
        XCTAssertEqual(r.validParents(for: "C").map(\.id).sorted(), ["A", "B", "D"])
    }

    func testDeletingAGroupReparentsChildrenAndDropsItsHotkey() throws {
        let r = try registry(["groups": [group("R", "R"), group("A", "A", parent: "R"), group("B", "B", parent: "A")],
                              "profiles": [profile("p1", "one", group: "A")],
                              "hotkeys": ["group-selectors": ["A": ["⌘-1"], "R": ["⌘-2"]]]])
        r.delete(groupId: "A")
        XCTAssertEqual(r.groups.first { $0.id == "B" }?.parentGroupId, "R", "children move up to the deleted group's parent")
        XCTAssertNil(r.config.value(at: ["hotkeys", "group-selectors", "A"]))
        XCTAssertNotNil(r.config.value(at: ["hotkeys", "group-selectors", "R"]))
        XCTAssertNil(r.userProfiles.first?.group, "its profiles move to Ungrouped")
        r.delete(groupId: "B", deleteProfiles: true)
        XCTAssertEqual(r.userProfiles.count, 1, "B had no profiles")
        r.save(ProfileGroup(id: "G", name: "G"))
        _ = r.save(Profile(config: profile("p2", "two", group: "G")))
        r.delete(groupId: "G", deleteProfiles: true)
        XCTAssertFalse(r.userProfiles.contains { $0.id == "p2" })
    }

    func testDeletingAProfileRemovesItsHotkey() throws {
        let id = "ssh:custom:a.b:1"
        let r = try registry(["profiles": [profile(id, "ab")], "hotkeys": ["profile": ["ssh:custom:a-b:1": ["⌘-7"]]]])
        let p = try XCTUnwrap(r.profile(withId: id))
        XCTAssertEqual(p.hotkeyName, "ssh:custom:a-b:1")
        XCTAssertEqual(p.hotkeyId, "profile.ssh:custom:a-b:1")
        r.delete(profileId: id)
        XCTAssertNil(r.config.value(at: ["hotkeys", "profile", "ssh:custom:a-b:1"]))
    }

    func testHideWritesTheBlacklist() throws {
        let r = try registry(["profiles": [profile("p1", "one")]])
        let builtin = try XCTUnwrap(r.profile(withId: "local:default"))
        r.setHidden(builtin, true)
        XCTAssertEqual(r.config.value("profileBlacklist")?.stringArrayValue, ["local:default"])
        XCTAssertTrue(r.isHidden(builtin))
        XCTAssertFalse(r.allProfiles().contains { $0.id == "local:default" })
        XCTAssertTrue(r.allProfiles(includeHidden: true).contains { $0.id == "local:default" }, "Show hidden lists the blacklist too")
        r.setHidden(builtin, false)
        XCTAssertEqual(r.config.value("profileBlacklist")?.stringArrayValue ?? [], [])
    }

    func testLegacyHiddenMovesToTheBlacklist() throws {
        var hidden = profile("p1", "one")
        hidden["hidden"] = true
        let r = try registry(["profiles": [hidden, profile("p2", "two")], "profileBlacklist": ["p2"]])
        r.migrateLegacyHidden()
        XCTAssertEqual(Set(r.config.value("profileBlacklist")?.stringArrayValue ?? []), ["p1", "p2"])
        XCTAssertNil(r.userProfiles.first { $0.id == "p1" }?.extra["hidden"])
        XCTAssertTrue(r.isHidden(try XCTUnwrap(r.profile(withId: "p1"))))
    }

    func testTypeDefaultsCanBeSetAndCleared() throws {
        let r = try registry([:])
        r.setTypeDefaults("ssh", ["options": ["port": 2200]])
        XCTAssertEqual(r.typeDefaults("ssh")["options"]?["port"]?.intValue, 2200)
        r.setTypeDefaults("ssh", nil)
        XCTAssertNil(r.typeDefaults("ssh")["options"]?["port"])
    }

    func testDefaultsPrecedence() throws {
        let r = try registry(["profileDefaults": ["ssh": ["options": ["port": 2200]]],
                              "groups": [group("G", "G", defaults: ["ssh": ["options": ["port": 2222]]])],
                              "profiles": [profile("in", "in", group: "G"), profile("own", "own", group: "G", options: ["host": "h", "port": 22]),
                                           profile("out", "out")]])
        XCTAssertEqual(r.resolved(try XCTUnwrap(r.profile(withId: "in"))).options["port"]?.intValue, 2222)
        XCTAssertEqual(r.resolved(try XCTUnwrap(r.profile(withId: "own"))).options["port"]?.intValue, 22)
        XCTAssertEqual(r.resolved(try XCTUnwrap(r.profile(withId: "out"))).options["port"]?.intValue, 2200)
    }

    func testSelectorFiltersByTypeAndGroup() throws {
        let r = try registry(["groups": [group("A", "A"), group("B", "B", parent: "A"), group("C", "C")],
                              "profiles": [profile("s1", "s1", group: "A"), profile("s2", "s2", group: "B"), profile("s3", "s3", group: "C"),
                                           profile("l1", "l1", type: "local", group: "A", options: ["command": "/bin/sh"])]])
        func ids(_ entries: [ProfileRegistry.SelectorEntry]) -> [String] {
            entries.compactMap { if case let .profile(p) = $0.kind { return p.id } else { return nil } }
        }
        XCTAssertEqual(Set(ids(r.selectorEntries(type: "local"))), ["l1"], "type filter drops built-in and other types")
        XCTAssertEqual(Set(ids(r.selectorEntries(groupId: "A"))), ["s1", "s2", "l1"], "a group and its subgroups")
        XCTAssertEqual(Set(ids(r.selectorEntries(type: "ssh", groupId: "A"))), ["s1", "s2"])
    }
}
