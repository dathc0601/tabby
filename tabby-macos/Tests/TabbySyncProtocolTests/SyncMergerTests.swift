import XCTest
import TabbySyncProtocol

final class SyncMergerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }
    let day: TimeInterval = 86_400

    func snapshot(_ device: String, profiles: ItemSection = ItemSection(), settings: TextSection? = nil,
                  knownHosts: TextSection? = nil) -> SyncSnapshot {
        SyncSnapshot(createdAt: ago(10), deviceId: device, settings: settings, profiles: profiles,
                     knownHosts: knownHosts)
    }

    func item(_ id: String, _ name: String, at date: Date) -> SyncItem {
        SyncItem(id: id, modifiedAt: date, value: ["name": .string(name)])
    }

    func merge(_ local: SyncSnapshot, _ remote: SyncSnapshot) -> SyncMergeResult {
        SyncMerger.merge(local: local, remote: remote, now: now)
    }

    // MARK: Items

    func testIdenticalSidesChangeNothing() {
        let profiles = ItemSection(items: [item("a", "A", at: ago(60))], deleted: [Tombstone(id: "b", deletedAt: ago(60))])
        let result = merge(snapshot("local", profiles: profiles), snapshot("remote", profiles: profiles))
        XCTAssertEqual(result.snapshot.profiles, profiles)
        XCTAssertFalse(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    func testRemoteOnlyItemIsAdded() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "A", at: ago(60))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "A", at: ago(60)), item("b", "B", at: ago(30))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items.map(\.id), ["a", "b"])
        XCTAssertTrue(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    func testLocalOnlyItemIsKeptAndUploaded() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "A", at: ago(60)), item("b", "B", at: ago(30))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "A", at: ago(60))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items.map(\.id), ["a", "b"])
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testNewerRemoteEditWins() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "old", at: ago(60))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "new", at: ago(30))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [item("a", "new", at: ago(30))])
        XCTAssertTrue(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    func testNewerLocalEditWins() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "new", at: ago(30))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "old", at: ago(60))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [item("a", "new", at: ago(30))])
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testTieGoesToLocal() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "mine", at: ago(30))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "theirs", at: ago(30))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [item("a", "mine", at: ago(30))])
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testDeleteNewerThanEditRemovesTheItem() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "A", at: ago(60))]))
        let remote = snapshot("remote", profiles: ItemSection(deleted: [Tombstone(id: "a", deletedAt: ago(30))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [])
        XCTAssertEqual(result.snapshot.profiles.deleted, [Tombstone(id: "a", deletedAt: ago(30))])
        XCTAssertTrue(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    func testLocalDeleteNewerThanRemoteEditIsUploaded() {
        let local = snapshot("local", profiles: ItemSection(deleted: [Tombstone(id: "a", deletedAt: ago(30))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "A", at: ago(60))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [])
        XCTAssertEqual(result.snapshot.profiles.deleted, [Tombstone(id: "a", deletedAt: ago(30))])
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testEditNewerThanDeleteBringsTheItemBack() {
        let local = snapshot("local", profiles: ItemSection(deleted: [Tombstone(id: "a", deletedAt: ago(60))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "edited", at: ago(30))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [item("a", "edited", at: ago(30))])
        XCTAssertEqual(result.snapshot.profiles.deleted, [], "the losing tombstone goes away")
        XCTAssertTrue(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    /// A tombstone hides an item with an older-or-equal timestamp, whichever side has it.
    func testDeleteAtTheSameTimeAsAnEditWins() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "A", at: ago(30))]))
        let remote = snapshot("remote", profiles: ItemSection(deleted: [Tombstone(id: "a", deletedAt: ago(30))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [])
        XCTAssertEqual(result.snapshot.profiles.deleted.map(\.id), ["a"])
        XCTAssertTrue(result.changedLocally)

        // On one side: the same id both listed and deleted.
        let both = snapshot("local", profiles: ItemSection(items: [item("b", "B", at: ago(30))],
                                                           deleted: [Tombstone(id: "b", deletedAt: ago(30))]))
        let merged = merge(both, both).snapshot.profiles
        XCTAssertEqual(merged.items, [])
        XCTAssertEqual(merged.deleted, [Tombstone(id: "b", deletedAt: ago(30))])
    }

    func testTombstonesOlderThanNinetyDaysAreDropped() {
        let local = snapshot("local", profiles: ItemSection(deleted: [
            Tombstone(id: "old", deletedAt: ago(91 * day)),
            Tombstone(id: "recent", deletedAt: ago(89 * day)),
        ]))
        let remote = snapshot("remote", profiles: ItemSection(deleted: [
            Tombstone(id: "old", deletedAt: ago(91 * day)),
            Tombstone(id: "recent", deletedAt: ago(89 * day)),
        ]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.deleted.map(\.id), ["recent"])
        XCTAssertEqual(SyncMerger.tombstoneLifetime, 90 * day)
    }

    /// An old tombstone still hides the older item it deleted before it is dropped, so the
    /// item does not come back from a device that was offline for a while.
    func testOldTombstoneStillHidesAnOlderItem() {
        let local = snapshot("local", profiles: ItemSection(deleted: [Tombstone(id: "a", deletedAt: ago(100 * day))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "A", at: ago(120 * day))]))
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.profiles.items, [])
        XCTAssertEqual(result.snapshot.profiles.deleted, [])
        XCTAssertTrue(result.needsUpload)
    }

    func testEverySectionIsMerged() {
        var local = snapshot("local")
        var remote = snapshot("remote")
        remote.groups = ItemSection(items: [item("g", "G", at: ago(1))])
        remote.secrets = ItemSection(items: [item("s", "S", at: ago(1))])
        local.keyFiles = ItemSection(items: [item("k", "K", at: ago(1))])
        let result = merge(local, remote)
        XCTAssertEqual(result.snapshot.groups.items.map(\.id), ["g"])
        XCTAssertEqual(result.snapshot.secrets.items.map(\.id), ["s"])
        XCTAssertEqual(result.snapshot.keyFiles.items.map(\.id), ["k"])
        XCTAssertTrue(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testLocalOrderIsKeptAndRemoteOnlyItemsFollow() {
        let local = snapshot("local", profiles: ItemSection(items: [item("z", "Z", at: ago(9)), item("a", "A", at: ago(9))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [
            item("m", "M", at: ago(9)), item("a", "A2", at: ago(1)), item("b", "B", at: ago(9)),
        ]))
        XCTAssertEqual(merge(local, remote).snapshot.profiles.items.map(\.id), ["z", "a", "m", "b"])
    }

    /// Dates travel with millisecond precision; a sub-millisecond difference is no change.
    func testSubMillisecondDifferencesAreTies() {
        let local = snapshot("local", profiles: ItemSection(items: [item("a", "A", at: ago(30).addingTimeInterval(0.0003))]))
        let remote = snapshot("remote", profiles: ItemSection(items: [item("a", "A", at: ago(30))]))
        let result = merge(local, remote)
        XCTAssertFalse(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    // MARK: Text sections

    func testNewerSettingsWinEitherWay() {
        let older = TextSection(updatedAt: ago(60), text: "old")
        let newer = TextSection(updatedAt: ago(30), text: "new")

        var result = merge(snapshot("local", settings: older), snapshot("remote", settings: newer))
        XCTAssertEqual(result.snapshot.settings, newer)
        XCTAssertTrue(result.changedLocally)
        XCTAssertFalse(result.needsUpload)

        result = merge(snapshot("local", settings: newer), snapshot("remote", settings: older))
        XCTAssertEqual(result.snapshot.settings, newer)
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testTextTieGoesToLocal() {
        let mine = TextSection(updatedAt: ago(30), text: "mine")
        let theirs = TextSection(updatedAt: ago(30), text: "theirs")
        let result = merge(snapshot("local", knownHosts: mine), snapshot("remote", knownHosts: theirs))
        XCTAssertEqual(result.snapshot.knownHosts, mine)
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)
    }

    func testNewerKnownHostsWin() {
        let older = TextSection(updatedAt: ago(60), text: "a")
        let newer = TextSection(updatedAt: ago(30), text: "a\nb")
        let result = merge(snapshot("local", knownHosts: older), snapshot("remote", knownHosts: newer))
        XCTAssertEqual(result.snapshot.knownHosts, newer)
        XCTAssertTrue(result.changedLocally)
    }

    func testMissingTextLosesToPresentText() {
        let text = TextSection(updatedAt: ago(30), text: "x")
        var result = merge(snapshot("local"), snapshot("remote", settings: text))
        XCTAssertEqual(result.snapshot.settings, text)
        XCTAssertTrue(result.changedLocally)
        XCTAssertFalse(result.needsUpload)

        result = merge(snapshot("local", knownHosts: text), snapshot("remote"))
        XCTAssertEqual(result.snapshot.knownHosts, text)
        XCTAssertFalse(result.changedLocally)
        XCTAssertTrue(result.needsUpload)

        result = merge(snapshot("local"), snapshot("remote"))
        XCTAssertNil(result.snapshot.settings)
        XCTAssertFalse(result.changedLocally)
        XCTAssertFalse(result.needsUpload)
    }

    // MARK: Snapshot header

    func testMergedSnapshotIsStampedForThisDevice() {
        var remote = snapshot("remote")
        remote.formatVersion = 2
        let result = merge(snapshot("local"), remote)
        XCTAssertEqual(result.snapshot.deviceId, "local")
        XCTAssertEqual(result.snapshot.createdAt, now)
        XCTAssertEqual(result.snapshot.formatVersion, SyncSnapshot.currentFormatVersion)
        XCTAssertFalse(result.changedLocally, "the header is not content")
        XCTAssertFalse(result.needsUpload)
    }
}
