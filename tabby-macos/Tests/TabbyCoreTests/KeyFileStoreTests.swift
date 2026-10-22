import XCTest
@testable import TabbyCore

/// Private keys that arrived through sync live in `<config>/keys/<id>`; a profile keeps its
/// original path, which resolves to the synced copy only when the file is missing here.
final class KeyFileStoreTests: XCTestCase {
    private var dir: URL!
    private let abc = String(repeating: "ab", count: 64)
    private let ed = String(repeating: "ed", count: 64)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("keys-\(UUID().uuidString.prefix(8))")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testStoredKeysAreOwnerOnlyAndIndexedByOriginalPath() throws {
        let store = KeyFileStore(directory: dir)
        try store.store(id: abc, originalPath: "~/.ssh/acme_ci", contents: Data("KEY".utf8), isDefaultIdentity: false)
        let path = store.path(for: abc)
        XCTAssertEqual(FileManager.default.contents(atPath: path), Data("KEY".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        XCTAssertEqual(KeyFileStore(directory: dir).records().map(\.originalPath), ["~/.ssh/acme_ci"], "the index survives a reload")
        store.remove(id: abc)
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The id names the file, and it arrives from the account: anything but a SHA-512 hex
    /// string could point outside the keys folder.
    func testOnlySHA512IDsAreStored() throws {
        let store = KeyFileStore(directory: dir)
        for bad in ["../escape", "abc", String(repeating: "AB", count: 64), String(repeating: "ab", count: 63) + "/x"] {
            XCTAssertThrowsError(try store.store(id: bad, originalPath: "~/.ssh/x", contents: Data("K".utf8), isDefaultIdentity: false), bad)
        }
        XCTAssertTrue(store.records().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escape").path))
        XCTAssertTrue(KeyFileStore.isValidID(abc))
    }

    func testMissingKeysResolveToTheSyncedCopy() throws {
        let store = KeyFileStore(directory: dir)
        try store.store(id: abc, originalPath: "~/.ssh/acme_ci", contents: Data("KEY".utf8), isDefaultIdentity: false)
        let keys = store.syncedKeys()
        XCTAssertEqual(keys.resolve("~/.ssh/acme_ci", fileExists: { _ in false }), store.path(for: abc))
        XCTAssertEqual(keys.resolve("~/.ssh/acme_ci", fileExists: { _ in true }), "~/.ssh/acme_ci", "a local file wins")
        XCTAssertEqual(keys.resolve("~/.ssh/other", fileExists: { _ in false }), "~/.ssh/other")
    }

    func testDefaultIdentitiesFillInForMissingLocalOnes() throws {
        let store = KeyFileStore(directory: dir)
        try store.store(id: ed, originalPath: "~/.ssh/id_ed25519", contents: Data("ED".utf8), isDefaultIdentity: true)
        let keys = store.syncedKeys()
        XCTAssertEqual(keys.identitiesForProfileWithoutKeys(fileExists: { _ in false }), [store.path(for: ed)])
        XCTAssertEqual(keys.identitiesForProfileWithoutKeys(fileExists: { $0.hasSuffix("id_rsa") }),
                       [NSHomeDirectory() + "/.ssh/id_rsa", store.path(for: ed)],
                       "local defaults stay in the list, since naming any IdentityFile stops ssh trying them")
        XCTAssertEqual(SyncedKeys.none.identitiesForProfileWithoutKeys(fileExists: { _ in false }), [])
    }

    func testGeneratorUsesSyncedKeys() throws {
        let store = KeyFileStore(directory: dir)
        try store.store(id: abc, originalPath: "~/.ssh/acme_ci_missing_here", contents: Data("KEY".utf8), isDefaultIdentity: false)
        let gen = SSHConfigGenerator(paths: .init(knownHostsFile: "/tmp/kh", controlDirectory: "/tmp/cm", syncedKeys: store.syncedKeys()))
        let out = try gen.generate(SSHOptions(["host": "example.com", "privateKeys": ["~/.ssh/acme_ci_missing_here"]]), jumpHostResolver: { _ in nil })
        XCTAssertTrue(out.config.contains("IdentityFile \(store.path(for: abc))"), out.config)
    }
}
