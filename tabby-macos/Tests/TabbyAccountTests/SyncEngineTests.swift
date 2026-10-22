import XCTest
import TabbyCore
import TabbySSH
import TabbySyncProtocol
@testable import TabbyAccount

/// One simulated Mac: its own config, Keychain, synced-key folder, known_hosts and home.
@MainActor
final class TestMac {
    let root: URL
    let config: ConfigStore
    let passwords = InMemoryPasswordStore()
    let keys: KeyFileStore
    let knownHosts: URL
    let home: URL
    let local: LocalSyncData
    var engine: SyncEngine!

    init(name: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(name)-\(UUID().uuidString.prefix(6))")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        config = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        keys = KeyFileStore(directory: root.appendingPathComponent("keys"))
        knownHosts = root.appendingPathComponent("known_hosts")
        local = LocalSyncData(config: config, passwords: passwords, keyStore: keys, knownHostsFile: knownHosts, homeDirectory: home.path)
    }

    func connect(_ session: AccountSession, server: FakeSyncServer) throws {
        let client = try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server, token: session.token)
        engine = SyncEngine(client: client, session: session, local: local, stateFile: root.appendingPathComponent("sync-state.json"))
    }

    func addProfile(id: String, name: String, host: String, keys: [String] = []) {
        var profiles = config.value("profiles")?.arrayValue ?? []
        var options: [String: ConfigValue] = ["host": .string(host), "user": "deploy", "port": 22]
        if !keys.isEmpty { options["privateKeys"] = .array(keys.map { .string($0) }) }
        profiles.append(["id": .string(id), "type": "ssh", "name": .string(name), "options": .object(options)])
        config.set("profiles", .array(profiles))
    }

    var profileNames: [String] { (config.value("profiles")?.arrayValue ?? []).compactMap { $0["name"]?.stringValue } }

    func writeKey(_ name: String, _ contents: String) throws -> String {
        let url = home.appendingPathComponent(".ssh").appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url.path
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor
final class SyncEngineTests: XCTestCase {
    var server: FakeSyncServer!
    var a: TestMac!
    var b: TestMac!

    override func setUp() async throws {
        AccountFlows.allowWeakKDFForTesting = true
        server = FakeSyncServer()
        a = try TestMac(name: "a")
        b = try TestMac(name: "b")
    }

    /// Registers on A and signs in on B.
    func signInBoth() async throws {
        let (sa, _) = try await AccountFlows.register(client: try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server),
                                                      email: "alex@example.com", password: "pw", device: testDevice, kdf: testKDF)
        try a.connect(sa, server: server)
        let sb = try await AccountFlows.signIn(client: try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server),
                                               email: "alex@example.com", password: "pw", device: testDevice)
        try b.connect(sb, server: server)
    }

    func testANewMacGetsProfilesPasswordsKeysKnownHostsAndSettings() async throws {
        try await signInBoth()
        let keyPath = try a.writeKey("acme_ci", "-----KEY ACME-----")
        a.addProfile(id: "ssh:prod", name: "prod-web-01", host: "prod.example.com", keys: [keyPath])
        a.passwords.savePassword("s3cret", host: "prod.example.com", port: 22, user: "deploy")
        a.config.set("account.approvedKeyFiles", .array([.string(LocalSyncData.keyID(Data("-----KEY ACME-----".utf8)))]))
        a.config.set("terminal.fontSize", 18)
        a.config.set("appearance.dockScreen", 42)
        try "prod.example.com ssh-ed25519 AAAA\n".write(to: a.knownHosts, atomically: true, encoding: .utf8)

        let first = try await a.engine.sync()
        XCTAssertTrue(first.uploaded)
        XCTAssertEqual(server.vaults.values.first?.revision, 1)

        let second = try await b.engine.sync()
        XCTAssertTrue(second.applied)
        XCTAssertEqual(b.profileNames, ["prod-web-01"])
        XCTAssertEqual(b.passwords.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret")
        XCTAssertEqual(b.config.value("terminal.fontSize")?.doubleValue, 18)
        XCTAssertNil(b.config.user.value(at: "appearance.dockScreen"), "the display a window docks on stays per Mac")
        XCTAssertNil(b.config.user.value(at: "account.approvedKeyFiles"), "account settings stay per Mac")
        XCTAssertEqual(try String(contentsOf: b.knownHosts, encoding: .utf8), "prod.example.com ssh-ed25519 AAAA\n")
        let stored = b.keys.syncedKeys().resolve(keyPath, fileExists: { _ in false })
        XCTAssertNotEqual(stored, keyPath, "the key resolves to its synced copy on B")
        XCTAssertEqual(FileManager.default.contents(atPath: stored), Data("-----KEY ACME-----".utf8))
        XCTAssertEqual(b.engine.recoveryKey, a.engine.session.recoveryKey, "B learns the recovery key from the vault")

        let third = try await b.engine.sync()
        XCTAssertFalse(third.uploaded, "nothing changed, nothing to upload")
        XCTAssertFalse(third.applied)
    }

    func testEditsOnBothMacsConverge() async throws {
        try await signInBoth()
        a.addProfile(id: "ssh:one", name: "one", host: "one.example.com")
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        b.addProfile(id: "ssh:two", name: "two", host: "two.example.com")
        var profiles = a.config.value("profiles")!.arrayValue!
        profiles[0]["name"] = "one (renamed)"
        a.config.set("profiles", .array(profiles))
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(a.profileNames, ["one (renamed)", "two"])
        XCTAssertEqual(b.profileNames, ["one (renamed)", "two"])
    }

    func testAConflictingUploadIsMergedAndRetried() async throws {
        try await signInBoth()
        a.addProfile(id: "ssh:one", name: "one", host: "one.example.com")
        _ = try await a.engine.sync()
        server.injectConflict = true
        a.addProfile(id: "ssh:two", name: "two", host: "two.example.com")
        let report = try await a.engine.sync()
        XCTAssertTrue(report.uploaded)
        XCTAssertEqual(server.log.filter { $0 == "PUT /v1/vault" }.count, 3, "first upload, the refused one, the retry")
        _ = try await b.engine.sync()
        XCTAssertEqual(b.profileNames, ["one", "two"])
    }

    func testDeletionsPropagate() async throws {
        try await signInBoth()
        a.addProfile(id: "ssh:one", name: "one", host: "one.example.com")
        a.addProfile(id: "ssh:two", name: "two", host: "two.example.com")
        a.passwords.savePassword("x", host: "one.example.com", port: 22, user: "deploy")
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.profileNames, ["one", "two"])
        a.config.set("profiles", .array([a.config.value("profiles")!.arrayValue![1]]))
        a.passwords.deletePassword(host: "one.example.com", port: 22, user: "deploy")
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.profileNames, ["two"])
        XCTAssertNil(b.passwords.password(host: "one.example.com", port: 22, user: "deploy"))
    }

    func testKeyFilesWaitForApproval() async throws {
        try await signInBoth()
        _ = try a.writeKey("id_ed25519", "-----DEFAULT-----")
        let report = try await a.engine.sync()
        XCTAssertEqual(report.pendingKeyFiles.map(\.originalPath), ["~/.ssh/id_ed25519"], "ssh's default identity is offered")
        _ = try await b.engine.sync()
        XCTAssertTrue(b.keys.records().isEmpty, "nothing uploads before it is approved")

        a.config.set("account.approvedKeyFiles", .array([.string(report.pendingKeyFiles[0].id)]))
        let again = try await a.engine.sync()
        XCTAssertTrue(again.pendingKeyFiles.isEmpty)
        _ = try await b.engine.sync()
        XCTAssertEqual(b.keys.records().map(\.originalPath), ["~/.ssh/id_ed25519"])
        XCTAssertEqual(b.keys.records().first?.isDefaultIdentity, true)

        a.config.set("account.approvedKeyFiles", .array([]))
        a.config.set("account.declinedKeyFiles", .array([.string(report.pendingKeyFiles[0].id)]))
        let declined = try await a.engine.sync()
        XCTAssertTrue(declined.pendingKeyFiles.isEmpty, "a declined key is not offered again")
    }

    func testPartsThatAreOffStayAsTheyAre() async throws {
        try await signInBoth()
        b.config.set("account.parts.secrets", false)
        a.passwords.savePassword("s3cret", host: "h.example.com", port: 22, user: "deploy")
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertNil(b.passwords.password(host: "h.example.com", port: 22, user: "deploy"))
        b.addProfile(id: "ssh:b", name: "from b", host: "b.example.com")
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        XCTAssertEqual(a.profileNames, ["from b"])
        XCTAssertEqual(a.passwords.password(host: "h.example.com", port: 22, user: "deploy"), "s3cret", "B's upload kept A's secrets")
    }

    func testKnownHostsAreMergedLineByLine() async throws {
        try await signInBoth()
        try "a.example.com ssh-ed25519 AAA\n".write(to: a.knownHosts, atomically: true, encoding: .utf8)
        _ = try await a.engine.sync()
        try "b.example.com ssh-ed25519 BBB\n".write(to: b.knownHosts, atomically: true, encoding: .utf8)
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        let expected = Set(["a.example.com ssh-ed25519 AAA", "b.example.com ssh-ed25519 BBB"])
        XCTAssertEqual(Set(try String(contentsOf: a.knownHosts, encoding: .utf8).split(separator: "\n").map(String.init)), expected)
        XCTAssertEqual(Set(try String(contentsOf: b.knownHosts, encoding: .utf8).split(separator: "\n").map(String.init)), expected)
    }

    func testRemoveSyncedDataDeletesWhatCameFromTheAccount() async throws {
        try await signInBoth()
        let keyPath = try a.writeKey("acme", "KEY")
        a.addProfile(id: "ssh:one", name: "one", host: "one.example.com", keys: [keyPath])
        a.config.set("account.approvedKeyFiles", .array([.string(LocalSyncData.keyID(Data("KEY".utf8)))]))
        a.passwords.savePassword("x", host: "one.example.com", port: 22, user: "deploy")
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        b.addProfile(id: "ssh:local", name: "only on b, not synced yet", host: "l.example.com")
        let counts = b.engine.syncedCounts
        XCTAssertEqual(counts.profiles, 1)
        XCTAssertEqual(counts.passwords, 1)
        XCTAssertEqual(counts.keys, 1)
        b.engine.removeSyncedData()
        XCTAssertEqual(b.profileNames, ["only on b, not synced yet"])
        XCTAssertNil(b.passwords.password(host: "one.example.com", port: 22, user: "deploy"))
        XCTAssertTrue(b.keys.records().isEmpty)
    }

    /// The account's settings win on a Mac's first sync; after that, its own edits sync out.
    func testSettingsEditedAfterTheFirstSyncSpreadBack() async throws {
        try await signInBoth()
        a.config.set("terminal.fontSize", 18)
        _ = try await a.engine.sync()
        b.config.set("terminal.fontSize", 11)
        _ = try await b.engine.sync()
        XCTAssertEqual(b.config.value("terminal.fontSize")?.doubleValue, 18, "first sync: the account wins")
        b.config.set("terminal.fontSize", 12)
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        XCTAssertEqual(a.config.value("terminal.fontSize")?.doubleValue, 12)
    }
}
