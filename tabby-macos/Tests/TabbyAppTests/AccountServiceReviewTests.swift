#if canImport(AppKit)
import XCTest
import Foundation
@testable import TabbyCore
@testable import TabbySSH
@testable import TabbyAccount
@testable import TabbyApp
import TabbySyncProtocol

/// Calls a hook right after GET /v1/vault answers, and can fail every request on demand.
final class ControllableTransport: HTTPTransport, @unchecked Sendable {
    struct Offline: Error {}
    let base: InMemorySyncServer
    var offline = false
    var afterVaultGet: (@MainActor () async -> Void)?
    init(_ base: InMemorySyncServer) { self.base = base }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if offline { throw Offline() }
        let result = try await base.send(request)
        if request.httpMethod == "GET", request.url?.path == APIPath.vault, let hook = afterVaultGet {
            afterVaultGet = nil
            await hook()
        }
        return result
    }
}

/// Regressions from the whole-branch review of the account service.
@MainActor
final class AccountServiceReviewTests: XCTestCase {
    var roots: [URL] = []

    override func setUp() {
        super.setUp()
        AccountFlows.allowWeakKDFForTesting = true
    }

    override func tearDown() {
        for r in roots { try? FileManager.default.removeItem(at: r) }
        super.tearDown()
    }

    func makeService(_ transport: HTTPTransport, persistent: SessionStore = MemorySessionStore(), poll: TimeInterval = 3600)
        throws -> (AccountService, ConfigStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acr-\(UUID().uuidString.prefix(6))")
        roots.append(root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/.ssh"), withIntermediateDirectories: true)
        let config = ConfigStore(defaults: try ConfigStore.bundledDefaults())
        let local = LocalSyncData(config: config, passwords: InMemoryPasswordStore(), keyStore: KeyFileStore(directory: root.appendingPathComponent("keys")),
                                  knownHostsFile: root.appendingPathComponent("kh"), homeDirectory: root.appendingPathComponent("home").path)
        let service = AccountService(local: local, stateFile: root.appendingPathComponent("sync-state.json"), transport: transport,
                                     baseURL: URL(string: "https://memory.invalid")!, persistentStore: persistent,
                                     debounceInterval: 0.05, pollInterval: poll, kdf: KDFParams(n: 1024, r: 8, p: 1, salt: Data(repeating: 9, count: 16)))
        return (service, config, root)
    }

    // I2
    func testSigningOutDuringASyncStaysSignedOut() async throws {
        let transport = ControllableTransport(InMemorySyncServer())
        let persistent = MemorySessionStore()
        let (service, _, root) = try makeService(transport, persistent: persistent)
        _ = try await service.register(email: "race@example.com", password: "pw", keepSignedIn: true)
        await service.finishRegistration()
        transport.afterVaultGet = { await service.signOut(removeSyncedData: false) }
        await service.syncNow()
        XCTAssertFalse(service.isSignedIn)
        XCTAssertEqual(service.status, .signedOut)
        XCTAssertNil(persistent.load(), "the session is not written back after sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync-state.json").path))
    }

    // I8
    func testAFailedSyncIsRetriedByThePoll() async throws {
        let transport = ControllableTransport(InMemorySyncServer())
        let (service, config, _) = try makeService(transport, poll: 0.2)
        _ = try await service.register(email: "offline@example.com", password: "pw", keepSignedIn: true)
        await service.finishRegistration()
        transport.offline = true
        config.set("terminal.fontSize", 20)
        await service.syncNow()
        guard case .failed = service.status else { return XCTFail("\(service.status)") }
        transport.offline = false
        let deadline = Date().addingTimeInterval(5)
        while service.status != .upToDate, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(service.status, .upToDate, "the poll retries a failed sync once the server answers again")
    }

    /// Found in the M7 walk: with Auto off, the other Mac's change still arrived within
    /// seconds. The poll synced whatever the setting said.
    func testAutoOffStopsThePollToo() async throws {
        let server = InMemorySyncServer()
        let (a, aConfig, _) = try makeService(server, poll: 0.1)
        _ = try await a.register(email: "auto@example.com", password: "pw", keepSignedIn: true)
        await a.finishRegistration()
        let (b, bConfig, _) = try makeService(server)
        try await b.signIn(email: "auto@example.com", password: "pw", keepSignedIn: false)

        aConfig.set("account.auto", false)
        aConfig.set("terminal.fontSize", 17)  // a local change waiting to upload
        a.localDataChanged()                   // as AppServices reports config changes
        XCTAssertTrue(a.hasLocalChanges)
        bConfig.set("terminal.fontSize", 21)
        await b.syncNow()
        try await Task.sleep(nanoseconds: 800_000_000)  // several polls
        XCTAssertEqual(aConfig.value("terminal.fontSize")?.doubleValue, 17, "nothing is pulled while Auto is off")
        XCTAssertTrue(a.hasLocalChanges, "nothing is pushed while Auto is off")

        await a.syncNow()
        XCTAssertFalse(a.hasLocalChanges, "Sync now still works")
    }

    /// Found in the M7 walk: removed from the other Mac, this one stayed signed in for minutes.
    /// With nothing to upload the poll only asks whether the vault changed, and dropped the 401.
    func testThePollSignsOutARemovedDevice() async throws {
        let server = InMemorySyncServer()
        let (a, _, _) = try makeService(server)
        _ = try await a.register(email: "gone@example.com", password: "pw", keepSignedIn: true)
        await a.finishRegistration()
        let (b, _, _) = try makeService(server, poll: 0.1)
        try await b.signIn(email: "gone@example.com", password: "pw", keepSignedIn: false)
        XCTAssertFalse(b.hasLocalChanges)

        await a.refreshDevices()
        let other = try XCTUnwrap(a.devices.first { !$0.isCurrent })
        try await a.removeDevice(other.id)
        let deadline = Date().addingTimeInterval(3)
        while b.isSignedIn, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(b.isSignedIn, "the poll notices the removal")
    }

    // I1 (app side): a change made while a sync runs is synced afterwards.
    func testAChangeDuringASyncIsSyncedAfterwards() async throws {
        let server = InMemorySyncServer()
        let transport = ControllableTransport(server)
        let (service, config, _) = try makeService(transport)
        _ = try await service.register(email: "busy@example.com", password: "pw", keepSignedIn: true)
        await service.finishRegistration()
        let before = server.vaults.values.first?.revision ?? 0
        transport.afterVaultGet = {
            config.set("terminal.fontSize", 21)
            service.localDataChanged()
        }
        await service.syncNow()
        let deadline = Date().addingTimeInterval(5)
        while (server.vaults.values.first?.revision ?? 0) < before + 1 || service.hasLocalChanges || service.status == .syncing,
              Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertGreaterThan(server.vaults.values.first?.revision ?? 0, before)
        XCTAssertFalse(service.hasLocalChanges)
    }

    // I5
    func testMemoryKeychainKeepsTheSessionOutOfTheRealKeychain() {
        XCTAssertTrue(AccountService.usesMemoryStores(environment: ["TABBYMAC_KEYCHAIN": "memory"]))
        XCTAssertTrue(AccountService.usesMemoryStores(environment: ["TABBYMAC_SYNC_URL": "memory:"]))
        XCTAssertFalse(AccountService.usesMemoryStores(environment: [:]))
    }
}
#endif
