import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import TabbyCore
import TabbySSH
import TabbySyncProtocol
@testable import TabbyAccount

/// A Keychain that can fail the way a real one does: listing errors (locked keychain,
/// denied prompt), unreadable items, refused writes.
final class FlakyPasswordStore: PasswordStore {
    struct ListingFailed: Error {}
    let base = InMemoryPasswordStore()
    var failListing = false
    var unreadable: Set<String> = []
    var refuseWrites = false

    func password(host: String, port: Int, user: String) -> String? {
        unreadable.contains(host) ? nil : base.password(host: host, port: port, user: user)
    }
    func hasPassword(host: String, port: Int, user: String) -> Bool { base.hasPassword(host: host, port: port, user: user) }
    func savePassword(_ password: String, host: String, port: Int, user: String) {
        if !refuseWrites { base.savePassword(password, host: host, port: port, user: user) }
    }
    func deletePassword(host: String, port: Int, user: String) { base.deletePassword(host: host, port: port, user: user) }
    func passphrase(keyID: String) -> String? { base.passphrase(keyID: keyID) }
    func savePassphrase(_ passphrase: String, keyID: String) { if !refuseWrites { base.savePassphrase(passphrase, keyID: keyID) } }
    func deletePassphrase(keyID: String) { base.deletePassphrase(keyID: keyID) }
    func savedSecrets() throws -> [SavedSecret] {
        if failListing { throw ListingFailed() }
        return try base.savedSecrets()
    }
}

/// Runs a hook on the main actor while GET /v1/vault is in flight.
final class HookTransport: HTTPTransport, @unchecked Sendable {
    let base: InMemorySyncServer
    var onVaultGet: (@MainActor () -> Void)?
    init(_ base: InMemorySyncServer) { self.base = base }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "GET", request.url?.path == APIPath.vault, let hook = onVaultGet {
            onVaultGet = nil
            await MainActor.run { hook() }
        }
        return try await base.send(request)
    }
}

/// Regressions from the phase 2 whole-branch review: "absent" must never mean "deleted".
@MainActor
final class ReviewRegressionTests: XCTestCase {
    var server: FakeSyncServer!
    var a: TestMac!
    var b: TestMac!

    override func setUp() async throws {
        AccountFlows.allowWeakKDFForTesting = true
        server = FakeSyncServer()
        a = try TestMac(name: "ra")
        b = try TestMac(name: "rb")
    }

    func session(_ register: Bool) async throws -> AccountSession {
        let client = try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server)
        if register {
            return try await AccountFlows.register(client: client, email: "r@example.com", password: "pw", device: testDevice, kdf: testKDF).0
        }
        return try await AccountFlows.signIn(client: client, email: "r@example.com", password: "pw", device: testDevice)
    }

    func flakyMac(_ store: FlakyPasswordStore, _ s: AccountSession) throws -> SyncEngine {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("flaky-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.ssh"), withIntermediateDirectories: true)
        let local = LocalSyncData(config: ConfigStore(defaults: try ConfigStore.bundledDefaults()), passwords: store,
                                  keyStore: KeyFileStore(directory: root.appendingPathComponent("keys")),
                                  knownHostsFile: root.appendingPathComponent("kh"), homeDirectory: root.appendingPathComponent("home").path)
        let client = try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server, token: s.token)
        return SyncEngine(client: client, session: s, local: local, stateFile: root.appendingPathComponent("state.json"))
    }

    // C1
    func testTurningAPartOffAndOnKeepsTheAccountsData() async throws {
        try a.connect(try await session(true), server: server)
        try b.connect(try await session(false), server: server)
        b.config.set("account.parts.profiles", false)
        _ = try await b.engine.sync()
        a.addProfile(id: "ssh:a1", name: "a1", host: "a1.example.com")
        a.addProfile(id: "ssh:a2", name: "a2", host: "a2.example.com")
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.profileNames, [], "off: B leaves its profiles alone")
        b.config.set("account.parts.profiles", true)
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        XCTAssertEqual(a.profileNames, ["a1", "a2"])
        XCTAssertEqual(b.profileNames, ["a1", "a2"], "turned back on, B receives them")
    }

    // C2: listing fails
    func testAFailedKeychainListingDeletesNothing() async throws {
        let flaky = FlakyPasswordStore()
        let engineA = try flakyMac(flaky, try await session(true))
        flaky.savePassword("s3cret", host: "prod.example.com", port: 22, user: "deploy")
        _ = try await engineA.sync()
        try b.connect(try await session(false), server: server)
        _ = try await b.engine.sync()
        flaky.failListing = true
        _ = try await engineA.sync()
        flaky.failListing = false
        _ = try await engineA.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.passwords.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret")
    }

    // C2: one item can't be read (a denied prompt)
    func testAnUnreadablePasswordIsNotDeleted() async throws {
        let flaky = FlakyPasswordStore()
        let engineA = try flakyMac(flaky, try await session(true))
        flaky.savePassword("s3cret", host: "prod.example.com", port: 22, user: "deploy")
        _ = try await engineA.sync()
        try b.connect(try await session(false), server: server)
        _ = try await b.engine.sync()
        flaky.unreadable = ["prod.example.com"]
        _ = try await engineA.sync()
        flaky.unreadable = []
        _ = try await engineA.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.passwords.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret")
    }

    // C2: a write fails while applying
    func testAFailedWriteIsRetriedNotDeleted() async throws {
        try a.connect(try await session(true), server: server)
        a.passwords.savePassword("s3cret", host: "prod.example.com", port: 22, user: "deploy")
        _ = try await a.engine.sync()
        let flaky = FlakyPasswordStore()
        let engineB = try flakyMac(flaky, try await session(false))
        flaky.refuseWrites = true
        _ = try await engineB.sync()
        XCTAssertNil(flaky.password(host: "prod.example.com", port: 22, user: "deploy"))
        flaky.refuseWrites = false
        _ = try await engineB.sync()
        _ = try await a.engine.sync()
        XCTAssertEqual(flaky.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret", "written at the next sync")
        XCTAssertEqual(a.passwords.password(host: "prod.example.com", port: 22, user: "deploy"), "s3cret", "never deleted on A")
    }

    // I1
    func testAnEditDuringASyncIsKept() async throws {
        let hook = HookTransport(server)
        let sa = try await session(true)
        a.engine = SyncEngine(client: try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: hook, token: sa.token),
                              session: sa, local: a.local, stateFile: a.root.appendingPathComponent("sync-state.json"))
        try b.connect(try await session(false), server: server)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        b.addProfile(id: "ssh:b1", name: "b1", host: "b1.example.com")
        _ = try await b.engine.sync()
        let mac = a!
        hook.onVaultGet = { mac.addProfile(id: "ssh:edit", name: "edited during sync", host: "e.example.com") }
        _ = try await a.engine.sync()
        XCTAssertEqual(Set(a.profileNames), ["b1", "edited during sync"])
        _ = try await b.engine.sync()
        XCTAssertEqual(Set(b.profileNames), ["b1", "edited during sync"])
    }

    // I3
    func testARotatedRecoveryKeyReachesOtherMacs() async throws {
        let sa = try await session(true)
        try a.connect(sa, server: server)
        try b.connect(try await session(false), server: server)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.engine.recoveryKey, sa.recoveryKey)
        let newKey = try await AccountFlows.rotateRecoveryKey(client: a.engine.client, session: a.engine.session, password: "pw")
        a.engine.setRecoveryKey(newKey.displayString)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        XCTAssertEqual(b.engine.recoveryKey, newKey.displayString)
        b.addProfile(id: "ssh:x", name: "x", host: "x.example.com")
        _ = try await b.engine.sync()
        let blob = try XCTUnwrap(server.vaults.values.first?.ciphertext)
        let snap = try VaultCrypto.openSnapshot(blob, using: try VaultCrypto.encryptionKey(from: sa.encryptionKey))
        XCTAssertEqual(snap.secrets.items.first { $0.id == "account:recovery-key" }?.value["value"]?.stringValue, newKey.displayString)
    }

    // I4
    func testAWeakKDFFromTheServerIsRefused() async throws {
        _ = try await AccountFlows.register(client: try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server),
                                            email: "weak@example.com", password: "pw", device: testDevice,
                                            kdf: KDFParams(n: 4, r: 1, p: 1, salt: Data(repeating: 1, count: 16)))
            .0
        AccountFlows.allowWeakKDFForTesting = false
        defer { AccountFlows.allowWeakKDFForTesting = true }
        do {
            _ = try await AccountFlows.signIn(client: try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server),
                                              email: "weak@example.com", password: "pw", device: testDevice)
            XCTFail("signed in with server-chosen KDF parameters below the minimum")
        } catch {
            XCTAssertEqual(error as? VaultCryptoError, .kdf)
        }
        XCTAssertFalse(server.log.contains("POST \(APIPath.session)"), "no authKey is sent for weak parameters")
        XCTAssertTrue(KDFParams.generate().isStrongEnough)
    }

    // I6
    func testARemovedHostKeyStaysRemoved() async throws {
        try a.connect(try await session(true), server: server)
        try b.connect(try await session(false), server: server)
        try "old.example.com ssh-ed25519 OLD\nkeep.example.com ssh-ed25519 KEEP\n".write(to: a.knownHosts, atomically: true, encoding: .utf8)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        try "keep.example.com ssh-ed25519 KEEP\n".write(to: a.knownHosts, atomically: true, encoding: .utf8)
        _ = try await a.engine.sync()
        _ = try await b.engine.sync()
        _ = try await a.engine.sync()
        XCTAssertEqual(try String(contentsOf: b.knownHosts, encoding: .utf8), "keep.example.com ssh-ed25519 KEEP\n")
        XCTAssertEqual(try String(contentsOf: a.knownHosts, encoding: .utf8), "keep.example.com ssh-ed25519 KEEP\n")
    }

    // "Remove synced data" after a relaunch, before any sync in that run.
    func testRemovingSyncedDataWorksAfterARelaunch() async throws {
        try a.connect(try await session(true), server: server)
        a.addProfile(id: "ssh:one", name: "one", host: "one.example.com")
        a.passwords.savePassword("x", host: "one.example.com", port: 22, user: "deploy")
        _ = try await a.engine.sync()
        let sb = try await session(false)
        try b.connect(sb, server: server)
        _ = try await b.engine.sync()
        try b.connect(sb, server: server)
        XCTAssertEqual(b.engine.syncedCounts, SyncEngine.SyncedCounts(profiles: 1, passwords: 1, keys: 0))
        b.engine.removeSyncedData()
        XCTAssertEqual(b.profileNames, [])
        XCTAssertNil(b.passwords.password(host: "one.example.com", port: 22, user: "deploy"))
    }
}
