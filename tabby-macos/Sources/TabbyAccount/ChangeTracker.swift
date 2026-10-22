import Crypto
import Foundation
import TabbySyncProtocol

/// Gives this Mac's syncable items their timestamps. Profiles, secrets and keys have none of
/// their own, so the tracker keeps a hash per item and stamps an item `now` when its hash
/// changes, and keeps a tombstone (with the time it was first missed) when it disappears.
/// After a merge is applied, `adopt` records the merged timestamps so the next observation
/// of the same data reports exactly the merge. Persisted as `sync-state.json`.
public struct ChangeTracker: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var hash: String
        var modifiedAt: Date
    }

    private var items: [String: [String: Entry]] = [:]
    private var deleted: [String: [String: Date]] = [:]
    private var texts: [String: Entry] = [:]

    public init() {}

    static func hash(_ value: JSONValue) -> String {
        let data = (try? SyncCoding.encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The section as it is now, in the given order, with tombstones for items that went away.
    public mutating func observe(_ section: String, items current: [(String, JSONValue)], now: Date) -> ItemSection {
        var known = items[section] ?? [:]
        var gone = deleted[section] ?? [:]
        var result: [SyncItem] = []
        var seen = Set<String>()
        for (id, value) in current where !seen.contains(id) {
            seen.insert(id)
            let h = Self.hash(value)
            if let entry = known[id], entry.hash == h {
                result.append(SyncItem(id: id, modifiedAt: entry.modifiedAt, value: value))
            } else {
                known[id] = Entry(hash: h, modifiedAt: now)
                result.append(SyncItem(id: id, modifiedAt: now, value: value))
            }
            gone[id] = nil
        }
        for id in known.keys where !seen.contains(id) {
            known[id] = nil
            gone[id] = gone[id] ?? now
        }
        items[section] = known
        deleted[section] = gone
        let tombstones = gone.map { Tombstone(id: $0.key, deletedAt: $0.value) }.sorted { $0.id < $1.id }
        return ItemSection(items: result, deleted: tombstones)
    }

    public mutating func observeText(_ section: String, text: String?, now: Date) -> TextSection? {
        guard let text else {
            texts[section] = nil
            return nil
        }
        let h = Self.hash(text)
        if let entry = texts[section], entry.hash == h {
            return TextSection(updatedAt: entry.modifiedAt, text: text)
        }
        texts[section] = Entry(hash: h, modifiedAt: now)
        return TextSection(updatedAt: now, text: text)
    }

    /// Records a merged section that has just been applied locally.
    public mutating func adopt(_ section: String, _ merged: ItemSection) {
        var known: [String: Entry] = [:]
        for item in merged.items { known[item.id] = Entry(hash: Self.hash(item.value), modifiedAt: item.modifiedAt) }
        items[section] = known
        deleted[section] = Dictionary(merged.deleted.map { ($0.id, $0.deletedAt) }, uniquingKeysWith: { a, _ in a })
    }

    public mutating func adoptText(_ section: String, _ merged: TextSection?) {
        texts[section] = merged.map { Entry(hash: Self.hash($0.text), modifiedAt: $0.updatedAt) }
    }

    /// Puts a section back the way it is in `other` (undoes this round's observation of a part
    /// that is off, or of data that could not be read completely).
    public mutating func restore(_ section: String, from other: ChangeTracker) {
        items[section] = other.items[section]
        deleted[section] = other.deleted[section]
        texts[section] = other.texts[section]
    }

    /// The items this Mac has in step with the account (for "Remove synced data").
    public func knownIDs(_ section: String) -> [String] {
        (items[section] ?? [:]).keys.sorted()
    }

    /// Whether this item, with this value, is in step with the account.
    public func knows(_ section: String, id: String, value: JSONValue) -> Bool {
        items[section]?[id]?.hash == Self.hash(value)
    }
}
