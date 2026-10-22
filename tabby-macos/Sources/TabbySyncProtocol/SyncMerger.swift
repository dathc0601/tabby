import Foundation

public struct SyncMergeResult: Hashable, Sendable {
    /// The merged snapshot, stamped with the local device id and `now`.
    public var snapshot: SyncSnapshot
    /// The local side lacks something the merge kept: the app must apply `snapshot`.
    public var changedLocally: Bool
    /// The remote side lacks something the merge kept: the app must upload `snapshot`.
    public var needsUpload: Bool
}

/// Merges a local and a remote snapshot. Pure; no I/O.
///
/// Item sections (profiles, groups, secrets, key files) merge per id. Each side's entry for
/// an id is its item (`modifiedAt`) or its tombstone (`deletedAt`); the later timestamp wins
/// across both sides. At equal timestamps a tombstone beats an item (a deletion hides an
/// item that is not newer than it), otherwise the local side wins. Tombstones older than
/// `tombstoneLifetime` are dropped after the merge, so they still hide the older items
/// they deleted first.
///
/// Text sections (settings, known hosts) merge as a whole: the later `updatedAt` wins, the
/// local side wins ties, and a missing section loses to a present one.
///
/// Timestamps are compared in milliseconds, the precision `SyncCoding` keeps on the wire.
/// Item order follows the local side, then the remote-only items in remote order.
public enum SyncMerger {
    public static let tombstoneLifetime: TimeInterval = 90 * 86_400

    public static func merge(local: SyncSnapshot, remote: SyncSnapshot, now: Date) -> SyncMergeResult {
        var changedLocally = false
        var needsUpload = false
        let cutoff = SyncCoding.milliseconds(now) - Int64(tombstoneLifetime * 1000)

        func items(_ path: KeyPath<SyncSnapshot, ItemSection>) -> ItemSection {
            let merged = mergeItems(local: local[keyPath: path], remote: remote[keyPath: path], cutoff: cutoff)
            let content = Entries(merged).content
            if content != Entries(local[keyPath: path]).content { changedLocally = true }
            if content != Entries(remote[keyPath: path]).content { needsUpload = true }
            return merged
        }

        func text(_ path: KeyPath<SyncSnapshot, TextSection?>) -> TextSection? {
            let merged = mergeText(local: local[keyPath: path], remote: remote[keyPath: path])
            if !sameText(merged, local[keyPath: path]) { changedLocally = true }
            if !sameText(merged, remote[keyPath: path]) { needsUpload = true }
            return merged
        }

        let snapshot = SyncSnapshot(
            createdAt: now,
            deviceId: local.deviceId,
            settings: text(\.settings),
            profiles: items(\.profiles),
            groups: items(\.groups),
            secrets: items(\.secrets),
            keyFiles: items(\.keyFiles),
            knownHosts: text(\.knownHosts)
        )
        return SyncMergeResult(snapshot: snapshot, changedLocally: changedLocally, needsUpload: needsUpload)
    }

    // MARK: Items

    static func mergeItems(local: ItemSection, remote: ItemSection, cutoff: Int64) -> ItemSection {
        let local = Entries(local)
        let remote = Entries(remote)
        var merged = ItemSection()
        for id in local.order + remote.order.filter({ local.byID[$0] == nil }) {
            let winner: Entry
            switch (local.byID[id], remote.byID[id]) {
            case let (l?, r?): winner = l.beats(r) ? l : r
            case let (l?, nil): winner = l
            case let (nil, r?): winner = r
            case (nil, nil): continue
            }
            switch winner {
            case .item(let item): merged.items.append(item)
            case .tombstone(let tombstone):
                if winner.millis >= cutoff { merged.deleted.append(tombstone) }
            }
        }
        return merged
    }

    private enum Entry {
        case item(SyncItem)
        case tombstone(Tombstone)

        var millis: Int64 {
            switch self {
            case .item(let item): SyncCoding.milliseconds(item.modifiedAt)
            case .tombstone(let tombstone): SyncCoding.milliseconds(tombstone.deletedAt)
            }
        }

        var isTombstone: Bool {
            if case .tombstone = self { return true }
            return false
        }

        /// Whether `self` (the preferred side) wins over `other`.
        func beats(_ other: Entry) -> Bool {
            if millis != other.millis { return millis > other.millis }
            if isTombstone != other.isTombstone { return isTombstone }
            return true
        }

        /// What the entry means, at wire precision.
        var content: Content {
            switch self {
            case .item(let item): Content(deleted: false, millis: millis, value: item.value)
            case .tombstone: Content(deleted: true, millis: millis, value: nil)
            }
        }
    }

    private struct Content: Equatable {
        var deleted: Bool
        var millis: Int64
        var value: JSONValue?
    }

    /// One side's section, one entry per id (an id listed twice keeps its winning entry).
    private struct Entries {
        var order: [String] = []
        var byID: [String: Entry] = [:]

        init(_ section: ItemSection) {
            for entry in section.items.map(Entry.item) + section.deleted.map(Entry.tombstone) {
                let id: String
                switch entry {
                case .item(let item): id = item.id
                case .tombstone(let tombstone): id = tombstone.id
                }
                if let existing = byID[id] {
                    if !existing.beats(entry) { byID[id] = entry }
                } else {
                    order.append(id)
                    byID[id] = entry
                }
            }
        }

        var content: [String: Content] { byID.mapValues(\.content) }
    }

    // MARK: Text

    static func mergeText(local: TextSection?, remote: TextSection?) -> TextSection? {
        guard let local else { return remote }
        guard let remote else { return local }
        return SyncCoding.milliseconds(remote.updatedAt) > SyncCoding.milliseconds(local.updatedAt) ? remote : local
    }

    private static func sameText(_ a: TextSection?, _ b: TextSection?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a.text == b.text && SyncCoding.milliseconds(a.updatedAt) == SyncCoding.milliseconds(b.updatedAt)
        default: false
        }
    }
}
