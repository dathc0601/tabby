import XCTest
import TabbySyncProtocol
@testable import TabbyAccount

/// Local profiles, secrets and keys carry no timestamps; the tracker remembers a hash per
/// item and stamps an item when it changes, and records a tombstone when one disappears.
final class ChangeTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    let t2 = Date(timeIntervalSince1970: 3_000)

    func testItemsAreStampedWhenTheyChange() {
        var tracker = ChangeTracker()
        var s = tracker.observe("profiles", items: [("a", .string("one")), ("b", .string("two"))], now: t0)
        XCTAssertEqual(s.items.map(\.modifiedAt), [t0, t0])
        s = tracker.observe("profiles", items: [("a", .string("one")), ("b", .string("TWO"))], now: t1)
        XCTAssertEqual(s.items.map(\.id), ["a", "b"])
        XCTAssertEqual(s.items.map(\.modifiedAt), [t0, t1], "only the changed item is restamped")
        XCTAssertTrue(s.deleted.isEmpty)
    }

    func testRemovedItemsLeaveATombstoneUntilTheyComeBack() {
        var tracker = ChangeTracker()
        _ = tracker.observe("profiles", items: [("a", .string("one")), ("b", .string("two"))], now: t0)
        var s = tracker.observe("profiles", items: [("a", .string("one"))], now: t1)
        XCTAssertEqual(s.deleted, [Tombstone(id: "b", deletedAt: t1)])
        s = tracker.observe("profiles", items: [("a", .string("one"))], now: t2)
        XCTAssertEqual(s.deleted, [Tombstone(id: "b", deletedAt: t1)], "the tombstone keeps its time")
        s = tracker.observe("profiles", items: [("a", .string("one")), ("b", .string("two"))], now: t2)
        XCTAssertTrue(s.deleted.isEmpty)
        XCTAssertEqual(s.items.last?.modifiedAt, t2)
    }

    func testAdoptingAMergeKeepsItsTimestamps() {
        var tracker = ChangeTracker()
        _ = tracker.observe("profiles", items: [("a", .string("local"))], now: t1)
        let merged = ItemSection(items: [SyncItem(id: "a", modifiedAt: t2, value: .string("remote")),
                                         SyncItem(id: "c", modifiedAt: t0, value: .string("new"))],
                                 deleted: [Tombstone(id: "z", deletedAt: t0)])
        tracker.adopt("profiles", merged)
        let s = tracker.observe("profiles", items: [("a", .string("remote")), ("c", .string("new"))], now: t2.addingTimeInterval(500))
        XCTAssertEqual(s.items, merged.items, "after applying the merge, the local data is the merge")
        XCTAssertEqual(s.deleted, merged.deleted)
    }

    func testTextSections() {
        var tracker = ChangeTracker()
        XCTAssertEqual(tracker.observeText("settings", text: "a: 1", now: t0), TextSection(updatedAt: t0, text: "a: 1"))
        XCTAssertEqual(tracker.observeText("settings", text: "a: 1", now: t1)?.updatedAt, t0)
        XCTAssertEqual(tracker.observeText("settings", text: "a: 2", now: t2)?.updatedAt, t2)
        XCTAssertNil(tracker.observeText("knownHosts", text: nil, now: t2))
        tracker.adoptText("settings", TextSection(updatedAt: t0, text: "b: 1"))
        XCTAssertEqual(tracker.observeText("settings", text: "b: 1", now: t2)?.updatedAt, t0)
    }

    func testRoundTripsThroughJSON() throws {
        var tracker = ChangeTracker()
        _ = tracker.observe("profiles", items: [("a", .string("one"))], now: t0)
        _ = tracker.observe("profiles", items: [], now: t1)
        _ = tracker.observeText("settings", text: "x", now: t0)
        let data = try SyncCoding.encoder.encode(tracker)
        XCTAssertEqual(try SyncCoding.decoder.decode(ChangeTracker.self, from: data), tracker)
    }
}
