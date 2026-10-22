import XCTest
import TabbySyncProtocol

final class SyncSnapshotTests: XCTestCase {
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000.123)

    static func sample() -> SyncSnapshot {
        SyncSnapshot(
            createdAt: t0,
            deviceId: "mac-a",
            settings: TextSection(updatedAt: t0, text: "terminal:\n  fontSize: 15\n"),
            profiles: ItemSection(
                items: [SyncItem(id: "p1", modifiedAt: t0, value: [
                    "name": "prod-db", "type": "ssh", "weight": 3, "isBuiltin": false,
                    "options": ["host": "10.0.0.5", "port": 22, "privateKeys": ["vault://abc"]],
                    "icon": nil,
                ])],
                deleted: [Tombstone(id: "p0", deletedAt: t0.addingTimeInterval(-60))]
            ),
            groups: ItemSection(items: [SyncItem(id: "g1", modifiedAt: t0, value: ["name": "Servers"])]),
            secrets: ItemSection(items: [SyncItem(id: "ssh:password|ssh@10.0.0.5:22|root", modifiedAt: t0,
                                                  value: ["type": "ssh:password", "value": "hunter2"])]),
            keyFiles: ItemSection(),
            knownHosts: TextSection(updatedAt: t0, text: "10.0.0.5 ssh-ed25519 AAAA\n")
        )
    }

    func testDefaultsForANewSnapshot() {
        let snapshot = SyncSnapshot(createdAt: Self.t0, deviceId: "d")
        XCTAssertEqual(snapshot.formatVersion, 1)
        XCTAssertEqual(SyncSnapshot.currentFormatVersion, 1)
        XCTAssertNil(snapshot.settings)
        XCTAssertNil(snapshot.knownHosts)
        XCTAssertEqual(snapshot.profiles, ItemSection())
        XCTAssertEqual(snapshot.profiles.items, [])
        XCTAssertEqual(snapshot.profiles.deleted, [])
    }

    func testRoundTripsThroughJSON() throws {
        let data = try SyncCoding.encoder.encode(Self.sample())
        XCTAssertEqual(try SyncCoding.decoder.decode(SyncSnapshot.self, from: data), Self.sample())
    }

    func testEncodingIsStable() throws {
        let a = try SyncCoding.encoder.encode(Self.sample())
        let b = try SyncCoding.encoder.encode(Self.sample())
        XCTAssertEqual(a, b)
        let json = String(decoding: a, as: UTF8.self)
        XCTAssertTrue(json.hasPrefix(#"{"createdAt":"2026-09-21T14:13:20.123Z","deviceId":"mac-a","formatVersion":1,"#), json)
        XCTAssertTrue(json.contains(#""deleted":[{"deletedAt":"2026-09-21T14:12:20.123Z","id":"p0"}]"#), json)
    }

    /// Dates keep milliseconds on the wire (a sync that rounded to seconds would see its own
    /// upload as older and upload again forever) and sub-millisecond precision is rounded.
    func testDatesUseISO8601WithMilliseconds() throws {
        let encoded = try SyncCoding.encoder.encode([Date(timeIntervalSince1970: 0.0006)])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["1970-01-01T00:00:00.001Z"]"#)
        let decoded = try SyncCoding.decoder.decode([Date].self, from: Data(
            #"["2026-09-21T14:13:20.123Z","2026-09-21T14:13:20Z","2026-09-21T16:13:20.5+02:00"]"#.utf8))
        XCTAssertEqual(decoded, [Self.t0, Date(timeIntervalSince1970: 1_790_000_000),
                                 Date(timeIntervalSince1970: 1_790_000_000.5)])
        XCTAssertThrowsError(try SyncCoding.decoder.decode([Date].self, from: Data(#"["yesterday"]"#.utf8)))
    }

    func testDecodingIgnoresUnknownFieldsAndMissingSections() throws {
        let json = #"""
        {"formatVersion": 2, "createdAt": "2026-09-21T14:13:20.123Z", "deviceId": "mac-b",
         "futureSection": {"x": 1},
         "profiles": {"items": [{"id": "p1", "modifiedAt": "2026-09-21T14:13:20.123Z",
                                 "value": {"name": "x"}, "futureItemField": true}]}}
        """#
        let snapshot = try SyncCoding.decoder.decode(SyncSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.formatVersion, 2)
        XCTAssertEqual(snapshot.profiles.items.map(\.id), ["p1"])
        XCTAssertEqual(snapshot.profiles.deleted, [])
        XCTAssertEqual(snapshot.groups, ItemSection())
        XCTAssertEqual(snapshot.secrets, ItemSection())
        XCTAssertEqual(snapshot.keyFiles, ItemSection())
        XCTAssertNil(snapshot.settings)
    }

    // MARK: JSONValue

    func testJSONValueKeepsEveryKindApart() throws {
        let value: JSONValue = ["a": [1, true, 0, false, "1", nil, 2.5, -3], "b": [:], "c": []]
        let data = try SyncCoding.encoder.encode(value)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"a":[1,true,0,false,"1",null,2.5,-3],"b":{},"c":[]}"#)
        XCTAssertEqual(try SyncCoding.decoder.decode(JSONValue.self, from: data), value)
    }

    func testJSONValueAccessors() {
        let value: JSONValue = ["name": "x", "port": 22, "on": true, "list": ["a"]]
        XCTAssertEqual(value["name"]?.stringValue, "x")
        XCTAssertEqual(value["port"]?.doubleValue, 22)
        XCTAssertEqual(value["on"]?.boolValue, true)
        XCTAssertEqual(value["list"]?.arrayValue, ["a"])
        XCTAssertNil(value["missing"])
        XCTAssertNil(JSONValue.string("x")["name"])
        XCTAssertEqual(value.objectValue?.count, 4)
        XCTAssertTrue(JSONValue.null.isNull)
    }
}
