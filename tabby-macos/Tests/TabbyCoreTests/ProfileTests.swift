import XCTest
@testable import TabbyCore

final class ProfileTests: XCTestCase {
    func makeRegistry(user: ConfigValue) throws -> ProfileRegistry {
        let store = ConfigStore(defaults: try ConfigStore.bundledDefaults(), user: user)
        let shells = [Shell(id: "default", name: "OS default (zsh)", command: "/bin/zsh", args: ["--login"])]
            + Shell.parseEtcShells("# comment\n/bin/bash\n/bin/zsh\n\n/opt/homebrew/bin/fish\n")
        return ProfileRegistry(
            config: store,
            providers: [LocalProfileProvider(shells: { shells }), SSHProfileProvider(sshConfig: { "Host devbox\n  HostName 10.0.0.5\n  User dev\n" })],
            recents: RecentProfilesStore(url: nil)
        )
    }

    func fixture() throws -> ConfigValue {
        let url = Bundle.module.url(forResource: "Fixtures/tabby-config", withExtension: "yaml")!
        return try YAMLCoding.parse(String(contentsOf: url, encoding: .utf8))
    }

    func testEtcShells() {
        let shells = Shell.parseEtcShells("/bin/bash\n# x\n /bin/zsh \n")
        XCTAssertEqual(shells.map(\.command), ["/bin/bash", "/bin/zsh"])
        XCTAssertEqual(shells.first?.id, "bin-bash".replacingOccurrences(of: "bin-", with: "binbash").isEmpty ? "" : Slug.make("/bin/bash"))
        XCTAssertEqual(shells.first?.args, ["-l"])
    }

    func testListingOrder() throws {
        let r = try makeRegistry(user: try fixture())
        let all = r.allProfiles()
        XCTAssertEqual(all.filter { !$0.isBuiltin }.map(\.name), ["bastion", "fish", "prod"], "ungrouped first, then Work")
        XCTAssertTrue(all.last!.isBuiltin)
        XCTAssertTrue(all.contains { $0.id == "local:default" })
        XCTAssertTrue(all.contains { $0.id == "ssh:ssh-config:devbox" })
        XCTAssertEqual(r.groupPath("1d1a0c7e-4a2c-4f0f-9cf2-8f4a6d1e2b3c"), "Work")
    }

    func testLayeredDefaults() throws {
        let r = try makeRegistry(user: try fixture())
        let prod = r.resolved(r.profile(withId: "ssh:custom:prod:1234")!)
        let o = SSHOptions(prod.options)
        XCTAssertEqual(o.host, "prod.example.com")
        XCTAssertEqual(o.port, 22, "provider default")
        XCTAssertEqual(o.keepaliveInterval, 15000, "group default")
        XCTAssertTrue(o.x11, "profileDefaults.ssh")
        XCTAssertEqual(o.auth, .publicKey)
        XCTAssertEqual(o.forwardedPorts.first?.targetPort, 80)
        XCTAssertEqual(o.jumpHost, "ssh:custom:bastion:5678")
        XCTAssertEqual(prod.behaviorOnSessionEnd, .auto)
        let fish = r.resolved(r.profile(withId: "local:custom:fish:abcd")!)
        XCTAssertEqual(LocalOptions(fish.options).env, ["FOO": "bar"])
    }

    func testSaveAndDelete() throws {
        let r = try makeRegistry(user: .emptyObject)
        let saved = r.save(Profile(type: "local", name: "My Shell", options: LocalOptions(command: "/bin/sh").configValue))
        XCTAssertTrue(saved.id.hasPrefix("local:custom:My-Shell:"), saved.id)
        XCTAssertEqual(r.userProfiles.count, 1)
        var edited = saved
        edited.name = "Renamed"
        r.save(edited)
        XCTAssertEqual(r.userProfiles.map(\.name), ["Renamed"])
        r.delete(profileId: saved.id)
        XCTAssertTrue(r.userProfiles.isEmpty)
    }

    func testSavingBuiltinCreatesCopy() throws {
        let r = try makeRegistry(user: .emptyObject)
        let builtin = r.profile(withId: "local:default")!
        let copy = r.save(builtin)
        XCTAssertNotEqual(copy.id, "local:default")
        XCTAssertFalse(copy.isBuiltin)
    }

    func testQuickConnect() {
        let p = SSHProfileProvider()
        let a = SSHOptions(p.quickConnect("me@host.example:2200")!.options)
        XCTAssertEqual(a.user, "me")
        XCTAssertEqual(a.host, "host.example")
        XCTAssertEqual(a.port, 2200)
        let b = SSHOptions(p.quickConnect("[::1]:2222")!.options)
        XCTAssertEqual(b.host, "::1")
        XCTAssertEqual(b.port, 2222)
        let c = p.quickConnect("a@b@host")!
        XCTAssertEqual(c.options["user"], "a@b")
        XCTAssertNil(p.quickConnect("  "))
        XCTAssertEqual(SSHProfileProvider.quickConnectString(SSHOptions(["host": "h", "user": "u", "port": 2022])), "u@h:2022")
    }

    func testSelectorEntries() throws {
        let r = try makeRegistry(user: try fixture())
        r.recents.push(r.profile(withId: "local:custom:fish:abcd")!)
        let entries = r.selectorEntries(query: "me@box")
        XCTAssertEqual(entries.first?.title, "fish")
        XCTAssertTrue(entries.first!.isRecent)
        XCTAssertEqual(entries[1].kind, .clearRecent)
        XCTAssertTrue(entries.contains { $0.kind == .manageProfiles })
        XCTAssertEqual(entries.last?.kind, .quickConnect(providerId: "ssh", query: "me@box"))
        XCTAssertFalse(entries.contains { if case .profile(let p) = $0.kind { return p.isTemplate } else { return false } })
    }

    func testProfileConfigRoundTrip() throws {
        let raw = try fixture()["profiles"]!.arrayValue!
        for v in raw {
            let p = Profile(config: v)
            XCTAssertEqual(Profile(config: p.configValue), p)
        }
        XCTAssertEqual(Profile(config: raw[0]).hotkeyId, "profile.ssh:custom:prod:1234")
    }
}
