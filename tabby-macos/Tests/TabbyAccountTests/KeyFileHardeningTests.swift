import XCTest
import TabbyCore
import TabbySyncProtocol
@testable import TabbyAccount

/// Key files arrive from the account; only ones whose id is the SHA-512 of their contents
/// are written.
@MainActor
final class KeyFileHardeningTests: XCTestCase {
    // async: Linux XCTest cannot discover synchronous tests on a @MainActor class.
    func testKeyFilesWhoseIDDoesNotMatchTheirContentsAreSkipped() async throws {
        let mac = try TestMac(name: "keys")
        let good = Data("-----GOOD-----".utf8)
        let goodID = LocalSyncData.keyID(good)
        func item(_ id: String, _ contents: Data) -> SyncItem {
            SyncItem(id: id, modifiedAt: Date(), value: .object([
                "originalPath": .string("~/.ssh/x"), "contents": .string(contents.base64EncodedString()),
                "isDefaultIdentity": .bool(false),
            ]))
        }
        let snapshot = SyncSnapshot(createdAt: Date(), deviceId: "other", keyFiles: ItemSection(items: [
            item("../../escape", good),
            item(String(repeating: "a", count: 128), good),
            item(goodID, good),
        ]))
        mac.local.apply(snapshot, over: mac.local.collect(recoveryKey: nil), parts: SyncParts(config: mac.config))
        XCTAssertEqual(mac.keys.records().map(\.id), [goodID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mac.root.appendingPathComponent("escape").path))
    }
}
