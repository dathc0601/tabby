#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbySSH
@testable import TabbyAccount
@testable import TabbyApp

/// The app's account service against an in-memory server: sign-up, a second Mac restoring
/// the account, automatic sync after a change, signing out.
@MainActor
final class AccountServiceTests: XCTestCase {
    let server = InMemorySyncServer()
    var roots: [URL] = []

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(at: r) }
        super.tearDown()
    }

    func makeMac() throws -> (AccountService, ConfigStore, InMemoryPasswordStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acct-\(UUID().uuidString.prefix(6))")
        roots.append(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.ssh"), withIntermediateDirectories: true)
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        let passwords = InMemoryPasswordStore()
        let local = LocalSyncData(config: config, passwords: passwords, keyStore: KeyFileStore(directory: root.appendingPathComponent("keys")),
                                  knownHostsFile: root.appendingPathComponent("known_hosts"), homeDirectory: root.appendingPathComponent("home").path)
        let service = AccountService(local: local, stateFile: root.appendingPathComponent("sync-state.json"), transport: server,
                                     baseURL: URL(string: "https://memory.invalid")!, persistentStore: MemorySessionStore(),
                                     debounceInterval: 0.05, pollInterval: 3600)
        return (service, config, passwords)
    }

    func addProfile(_ config: ConfigStore, _ name: String) {
        var list = config.value("profiles")?.arrayValue ?? []
        list.append(["id": .string("ssh:\(name)"), "type": "ssh", "name": .string(name), "options": ["host": .string("\(name).example.com")]])
        config.set("profiles", .array(list))
    }

    func testSignUpThenRestoreOnASecondMac() async throws {
        let (a, aConfig, aPasswords) = try makeMac()
        addProfile(aConfig, "prod")
        aPasswords.savePassword("s3cret", host: "prod.example.com", port: 22, user: "deploy")
        let recovery = try await a.register(email: "alex@example.com", password: "pw", keepSignedIn: true)
        XCTAssertTrue(a.isSignedIn)
        XCTAssertEqual(a.session?.recoveryKey, recovery.displayString)
        XCTAssertTrue(server.vaults.isEmpty, "nothing uploads before the recovery key step is done")
        await a.finishRegistration()
        XCTAssertEqual(a.status, .upToDate)
        XCTAssertEqual(server.vaults.count, 1)
        XCTAssertEqual(a.counts.profiles, 1)

        let (b, bConfig, bPasswords) = try makeMac()
        try await b.signIn(email: "alex@example.com", password: "pw", keepSignedIn: false)
        XCTAssertFalse(b.isRestoring)
        XCTAssertEqual(bConfig.value("profiles")?.arrayValue?.first?["name"]?.stringValue, "prod")
        XCTAssertEqual(bPasswords.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret")
        XCTAssertEqual(b.session?.recoveryKey, recovery.displayString, "the recovery key comes with the vault")
    }

    /// Signing in replaces this Mac's settings with the account's; what was here before is
    /// kept next to config.yaml.
    func testSigningInKeepsACopyOfTheSettingsItReplaces() async throws {
        let (a, aConfig, _) = try makeMac()
        aConfig.set("terminal.fontSize", 18)
        _ = try await a.register(email: "alex@example.com", password: "pw", keepSignedIn: true)
        await a.finishRegistration()

        let (b, bConfig, _) = try makeMac()
        bConfig.set("terminal.fontSize", 11)
        addProfile(bConfig, "only-on-b")
        let backup = b.stateFile.deletingLastPathComponent().appendingPathComponent("config.yaml.before-sign-in")
        try await b.signIn(email: "alex@example.com", password: "pw", keepSignedIn: false)
        XCTAssertEqual(bConfig.value("terminal.fontSize")?.doubleValue, 18, "the account's settings won")
        let text = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertTrue(text.contains("fontSize: 11"), text)
        XCTAssertTrue(text.contains("only-on-b"), text)
    }

    func testAChangeSyncsOnItsOwn() async throws {
        let (a, aConfig, _) = try makeMac()
        _ = try await a.register(email: "a@b.co", password: "pw", keepSignedIn: true)
        await a.finishRegistration()
        let revision = server.vaults.values.first?.revision
        addProfile(aConfig, "later")
        a.localDataChanged()
        XCTAssertTrue(a.hasLocalChanges)
        let deadline = Date().addingTimeInterval(5)
        while server.vaults.values.first?.revision == revision, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(server.vaults.values.first?.revision, (revision ?? 0) + 1)
        XCTAssertFalse(a.hasLocalChanges)
    }

    func testSigningOutCanRemoveWhatCameFromTheAccount() async throws {
        let (a, aConfig, _) = try makeMac()
        addProfile(aConfig, "shared")
        _ = try await a.register(email: "a@b.co", password: "pw", keepSignedIn: true)
        await a.finishRegistration()
        let (b, bConfig, _) = try makeMac()
        addProfile(bConfig, "made-on-b")
        try await b.signIn(email: "a@b.co", password: "pw", keepSignedIn: true)
        XCTAssertEqual(bConfig.value("profiles")?.arrayValue?.count, 2)
        XCTAssertEqual(b.removableCounts.profiles, 1, "the sign-out sheet counts only what came from the account")
        await b.signOut(removeSyncedData: true)
        XCTAssertFalse(b.isSignedIn)
        XCTAssertEqual(b.status, .signedOut)
        XCTAssertEqual(bConfig.value("profiles")?.arrayValue?.compactMap { $0["name"]?.stringValue }, ["made-on-b"])
        XCTAssertEqual(aConfig.value("profiles")?.arrayValue?.count, 1, "the other Mac keeps it")
    }

    func testARemovedDeviceIsSignedOut() async throws {
        let (a, _, _) = try makeMac()
        _ = try await a.register(email: "a@b.co", password: "pw", keepSignedIn: true)
        await a.finishRegistration()
        let (b, _, _) = try makeMac()
        try await b.signIn(email: "a@b.co", password: "pw", keepSignedIn: true)
        await a.refreshDevices()
        XCTAssertEqual(a.devices.count, 2)
        let other = try XCTUnwrap(a.devices.first { !$0.isCurrent })
        try await a.removeDevice(other.id)
        XCTAssertEqual(a.devices.count, 1)
        await b.syncNow()
        XCTAssertFalse(b.isSignedIn)
        if case .failed = b.status {} else { XCTFail("\(b.status)") }
    }
}
#endif
