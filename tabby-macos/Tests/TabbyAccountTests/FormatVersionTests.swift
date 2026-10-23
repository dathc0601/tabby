import XCTest
import TabbyCore
import TabbySyncProtocol
@testable import TabbyAccount

/// A vault written by a newer TabbyMac may hold sections this version does not know;
/// merging and re-uploading it would drop them for every Mac.
@MainActor
final class FormatVersionTests: XCTestCase {
    func testAVaultFromANewerVersionIsNeitherMergedNorOverwritten() async throws {
        AccountFlows.allowWeakKDFForTesting = true
        let server = FakeSyncServer()
        let mac = try TestMac(name: "fmt")
        let (session, _) = try await AccountFlows.register(
            client: try SyncClient(baseURL: URL(string: "https://sync.example.com")!, transport: server),
            email: "alex@example.com", password: "pw", device: testDevice, kdf: testKDF)
        try mac.connect(session, server: server)
        _ = try await mac.engine.sync()

        // Another Mac, on a newer version, rewrites the vault.
        let key = try VaultCrypto.encryptionKey(from: session.encryptionKey)
        var newer = SyncSnapshot(createdAt: Date(), deviceId: "newer-mac", profiles: ItemSection(items: [
            SyncItem(id: "ssh:future", modifiedAt: Date(), value: .object(["name": .string("future"), "type": .string("ssh")])),
        ]))
        newer.formatVersion = SyncSnapshot.currentFormatVersion + 1
        let accountID = try XCTUnwrap(server.vaults.keys.first)
        let stored = try XCTUnwrap(server.vaults[accountID])
        server.vaults[accountID] = VaultDTO(revision: stored.revision + 1, modifiedAt: Date(), deviceId: stored.deviceId,
                                            ciphertext: try VaultCrypto.sealSnapshot(newer, using: key))
        let before = server.vaults[accountID]

        mac.addProfile(id: "ssh:local", name: "local", host: "local.example.com")
        do {
            _ = try await mac.engine.sync()
            XCTFail("synced with a vault from a newer version")
        } catch let error as SyncEngineError {
            XCTAssertEqual(error, .newerVaultFormat)
            XCTAssertTrue(error.localizedDescription.contains("Update TabbyMac"), error.localizedDescription)
        }
        XCTAssertEqual(server.vaults[accountID], before, "nothing was uploaded over it")
        XCTAssertEqual(mac.profileNames, ["local"], "nothing was applied here")
    }
}
