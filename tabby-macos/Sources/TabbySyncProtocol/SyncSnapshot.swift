import Foundation

/// One synced object (a profile, a group, a secret, a key file), keyed by a stable id.
/// The payload is opaque to the protocol; the app maps it to and from its own types.
public struct SyncItem: Codable, Hashable, Sendable {
    public var id: String
    public var modifiedAt: Date
    public var value: JSONValue

    public init(id: String, modifiedAt: Date, value: JSONValue) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.value = value
    }
}

/// Records that an item was deleted, so the deletion wins over older copies on other devices.
/// Tombstones older than `SyncMerger.tombstoneLifetime` are dropped.
public struct Tombstone: Codable, Hashable, Sendable {
    public var id: String
    public var deletedAt: Date

    public init(id: String, deletedAt: Date) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

/// A set of items merged one by one.
public struct ItemSection: Codable, Hashable, Sendable {
    public var items: [SyncItem]
    public var deleted: [Tombstone]

    public init(items: [SyncItem] = [], deleted: [Tombstone] = []) {
        self.items = items
        self.deleted = deleted
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([SyncItem].self, forKey: .items) ?? []
        deleted = try container.decodeIfPresent([Tombstone].self, forKey: .deleted) ?? []
    }
}

/// A blob of text merged as a whole (the settings YAML, the known_hosts file).
public struct TextSection: Codable, Hashable, Sendable {
    public var updatedAt: Date
    public var text: String

    public init(updatedAt: Date, text: String) {
        self.updatedAt = updatedAt
        self.text = text
    }
}

/// Everything one account syncs, as stored (encrypted) in the vault. Readers ignore fields
/// they do not know and treat missing sections as empty, so newer clients can add sections.
public struct SyncSnapshot: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var createdAt: Date
    public var deviceId: String
    public var settings: TextSection?
    public var profiles: ItemSection
    public var groups: ItemSection
    public var secrets: ItemSection
    public var keyFiles: ItemSection
    public var knownHosts: TextSection?

    public init(
        formatVersion: Int = SyncSnapshot.currentFormatVersion,
        createdAt: Date,
        deviceId: String,
        settings: TextSection? = nil,
        profiles: ItemSection = ItemSection(),
        groups: ItemSection = ItemSection(),
        secrets: ItemSection = ItemSection(),
        keyFiles: ItemSection = ItemSection(),
        knownHosts: TextSection? = nil
    ) {
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.deviceId = deviceId
        self.settings = settings
        self.profiles = profiles
        self.groups = groups
        self.secrets = secrets
        self.keyFiles = keyFiles
        self.knownHosts = knownHosts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        settings = try container.decodeIfPresent(TextSection.self, forKey: .settings)
        profiles = try container.decodeIfPresent(ItemSection.self, forKey: .profiles) ?? ItemSection()
        groups = try container.decodeIfPresent(ItemSection.self, forKey: .groups) ?? ItemSection()
        secrets = try container.decodeIfPresent(ItemSection.self, forKey: .secrets) ?? ItemSection()
        keyFiles = try container.decodeIfPresent(ItemSection.self, forKey: .keyFiles) ?? ItemSection()
        knownHosts = try container.decodeIfPresent(TextSection.self, forKey: .knownHosts)
    }
}
