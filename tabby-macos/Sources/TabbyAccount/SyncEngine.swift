import Crypto
import Foundation
import TabbyCore
import TabbySyncProtocol

public struct SyncReport: Equatable, Sendable {
    public init() {}

    /// A new vault revision was uploaded.
    public var uploaded = false
    /// Changes from other Macs were written to this one.
    public var applied = false
    /// Key files waiting for the user's yes or no before they upload.
    public var pendingKeyFiles: [KeyFileCandidate] = []
}

public enum SyncEngineError: Error, LocalizedError, Equatable {
    case tooManyConflicts
    /// The vault was written by a newer TabbyMac; merging it here could drop what it added.
    case newerVaultFormat

    public var errorDescription: String? {
        switch self {
        case .tooManyConflicts:
            return "Another Mac kept changing the account while this one synced. Try again in a moment."
        case .newerVaultFormat:
            return "Another Mac synced with a newer TabbyMac. Update TabbyMac to keep syncing on this Mac."
        }
    }
}

/// One sync: read this Mac's data, download and decrypt the vault, merge, write what other
/// Macs changed, and upload when the server lacks something (retrying on a stale revision).
@MainActor
public final class SyncEngine {
    public let client: SyncClient
    public private(set) var session: AccountSession
    public let local: LocalSyncData
    let stateFile: URL
    let now: () -> Date

    /// The vault revision this Mac last saw.
    public private(set) var revision: Int?
    /// The last merged snapshot (what this Mac and the server agree on).
    public private(set) var lastSnapshot: SyncSnapshot?

    struct State: Codable {
        var tracker = ChangeTracker()
        var revision: Int?
    }

    public init(client: SyncClient, session: AccountSession, local: LocalSyncData, stateFile: URL, now: @escaping () -> Date = Date.init) {
        self.client = client
        self.session = session
        self.local = local
        self.stateFile = stateFile
        self.now = now
        revision = loadState().revision
    }

    /// The account's recovery key once known here (created here, or read from the vault).
    public var recoveryKey: String? { session.recoveryKey }

    private func loadState() -> State {
        guard let data = try? Data(contentsOf: stateFile) else { return State() }
        return (try? SyncCoding.decoder.decode(State.self, from: data)) ?? State()
    }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SyncCoding.encoder.encode(state).write(to: stateFile, options: .atomic)
    }

    /// Whether the server has a revision this Mac has not seen.
    public func remoteHasChanged() async throws -> Bool {
        let head = try await client.vaultHead()
        return head?.revision != revision
    }

    static let itemSections = ["profiles", "groups", "secrets", "keyFiles", "knownHostLines"]

    static func section(_ name: String, of snapshot: SyncSnapshot) -> ItemSection {
        switch name {
        case "profiles": return snapshot.profiles
        case "groups": return snapshot.groups
        case "secrets": return snapshot.secrets
        case "keyFiles": return snapshot.keyFiles
        default: return snapshot.knownHostLines
        }
    }

    static func isOn(_ section: String, _ parts: SyncParts) -> Bool {
        switch section {
        case "profiles", "groups": return parts.profiles
        case "secrets", "keyFiles": return parts.secrets
        case "knownHostLines": return parts.knownHosts
        default: return parts.settings
        }
    }

    /// Stops an in-flight sync (signing out): it throws `CancellationError` at its next step
    /// and writes nothing more.
    public func cancel() { isCancelled = true }
    public private(set) var isCancelled = false

    private func checkCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    public func sync() async throws -> SyncReport {
        let key = try VaultCrypto.encryptionKey(from: session.encryptionKey)
        for _ in 0..<4 {
            try checkCancelled()
            var report = SyncReport()
            let parts = SyncParts(config: local.config)
            let original = loadState()
            var state = original
            let accountKeys = Set(state.tracker.knownIDs("keyFiles"))
            let collected = local.collect(recoveryKey: session.recoveryKey, accountKeyIDs: accountKeys)
            let fingerprint = local.fingerprint()
            report.pendingKeyFiles = collected.pendingKeyFiles
            let time = now()
            func observe(_ name: String, _ items: [(String, JSONValue)]) -> ItemSection {
                var section = state.tracker.observe(name, items: items, now: time)
                // Missing from an incomplete read is not deleted.
                if collected.incomplete.contains(name) { section.deleted = [] }
                return section
            }
            var mine = SyncSnapshot(
                createdAt: time, deviceId: session.deviceID.uuidString,
                settings: state.tracker.observeText("settings", text: collected.settings, now: time),
                profiles: observe("profiles", collected.profiles),
                groups: observe("groups", collected.groups),
                secrets: observe("secrets", collected.secrets),
                keyFiles: observe("keyFiles", collected.keyFiles),
                knownHostLines: observe("knownHostLines", collected.knownHostLines))

            let remote = try await client.vault()
            try checkCancelled()
            // Something changed here while the server answered: start over with it.
            if local.fingerprint() != fingerprint { continue }

            var merged = mine
            var changedLocally = false
            var needsUpload = true
            if let remote {
                let theirs = try VaultCrypto.openSnapshot(remote.ciphertext, using: key)
                guard theirs.formatVersion <= SyncSnapshot.currentFormatVersion else { throw SyncEngineError.newerVaultFormat }
                // Parts that are off here: keep the server's copy and leave this Mac alone.
                if !parts.profiles { mine.profiles = theirs.profiles; mine.groups = theirs.groups }
                if !parts.secrets { mine.secrets = theirs.secrets; mine.keyFiles = theirs.keyFiles }
                if !parts.knownHosts { mine.knownHostLines = theirs.knownHostLines }
                if !parts.settings { mine.settings = theirs.settings }
                // A Mac's first sync with an existing account restores the account's settings
                // (the design's "Welcome back"); its own were never edited "after" them.
                if original.revision == nil, theirs.settings != nil { mine.settings = theirs.settings }
                // Older vaults kept known_hosts as one text; keep its lines.
                if theirs.knownHostLines.items.isEmpty, theirs.knownHostLines.deleted.isEmpty, let legacy = theirs.knownHosts {
                    mine.knownHostLines.items += LocalSyncData.lines(legacy.text)
                        .filter { line in !mine.knownHostLines.items.contains { $0.id == LocalSyncData.lineID(line) } }
                        .map { SyncItem(id: LocalSyncData.lineID($0), modifiedAt: legacy.updatedAt, value: .string($0)) }
                }
                let result = SyncMerger.merge(local: mine, remote: theirs, now: time)
                merged = result.snapshot
                merged.knownHosts = nil
                changedLocally = result.changedLocally
                needsUpload = result.needsUpload || theirs.knownHosts != nil
            }

            // Keys the account already holds are not this Mac's to offer (a Mac's first sync
            // collects before it knows the account's key ids).
            let accountKeyIDs = Set(merged.keyFiles.items.map(\.id))
            report.pendingKeyFiles.removeAll { accountKeyIDs.contains($0.id) }

            var after = collected
            if changedLocally {
                local.apply(merged, over: collected, parts: parts)
                report.applied = true
                learnRecoveryKey(from: merged)
                after = local.collect(recoveryKey: session.recoveryKey, accountKeyIDs: accountKeys.union(merged.keyFiles.items.map(\.id)))
            } else {
                learnRecoveryKey(from: merged)
            }

            // Record only what this Mac now really has: a write that failed is not "known",
            // so it is applied again next time instead of being taken for a deletion.
            for name in Self.itemSections {
                let section = Self.section(name, of: merged)
                guard Self.isOn(name, parts), !collected.incomplete.contains(name), !after.incomplete.contains(name) else {
                    state.tracker.restore(name, from: original.tracker)
                    continue
                }
                let present = after.ids(name)
                state.tracker.adopt(name, ItemSection(items: section.items.filter { present[$0.id] == $0.value }, deleted: section.deleted))
                state.tracker.markFromAccount(name, ids: Set(present.keys).subtracting(collected.ids(name).keys))
            }
            if parts.settings, after.settings == merged.settings?.text {
                state.tracker.adoptText("settings", merged.settings)
            } else {
                state.tracker.restore("settings", from: original.tracker)
            }

            try checkCancelled()
            if needsUpload {
                let blob = try VaultCrypto.sealSnapshot(merged, using: key)
                let put = try await client.putVault(blob, ifMatch: remote?.revision ?? 0)
                try checkCancelled()
                switch put {
                case .saved(let response):
                    state.revision = response.revision
                    report.uploaded = true
                case .conflict:
                    // Someone uploaded in between; what was applied stays, the tracker now
                    // matches it, and the next round merges with the newer vault.
                    saveState(state)
                    continue
                }
            } else {
                state.revision = remote?.revision
            }
            saveState(state)
            revision = state.revision
            lastSnapshot = merged
            return report
        }
        throw SyncEngineError.tooManyConflicts
    }

    /// The vault holds the account's current recovery key; a rotation on another Mac replaces
    /// the one this Mac knew.
    private func learnRecoveryKey(from snapshot: SyncSnapshot) {
        guard let item = snapshot.secrets.items.first(where: { $0.id == "account:recovery-key" }),
              let value = item.value["value"]?.stringValue, value != session.recoveryKey else { return }
        session.recoveryKey = value
    }

    /// After a recovery key rotation.
    public func setRecoveryKey(_ key: String) {
        session.recoveryKey = key
    }

    // MARK: Signing out

    public struct SyncedCounts: Equatable, Sendable {
        public var profiles = 0
        public var passwords = 0
        public var keys = 0

        public init(profiles: Int = 0, passwords: Int = 0, keys: Int = 0) {
            self.profiles = profiles
            self.passwords = passwords
            self.keys = keys
        }
    }

    /// What came from the account, for the sign-out choice ("Deletes 23 profiles, 6 passwords
    /// and 3 keys from this Mac only").
    public var syncedCounts: SyncedCounts {
        let tracker = loadState().tracker
        let secrets = tracker.knownIDs("secrets").filter { $0.hasPrefix("ssh:password|") || $0.hasPrefix("ssh:key-passphrase|") }
        return SyncedCounts(profiles: tracker.knownIDs("profiles").count, passwords: secrets.count, keys: tracker.knownIDs("keyFiles").count)
    }

    /// What "Remove synced data" deletes: what arrived from the account, not what this Mac
    /// brought (its own items stay even after they were uploaded).
    public var removableCounts: SyncedCounts {
        let tracker = loadState().tracker
        let secrets = tracker.fromAccountIDs("secrets").filter { $0.hasPrefix("ssh:password|") || $0.hasPrefix("ssh:key-passphrase|") }
        // Every file in `<config>/keys` is a copy from the account, and removal empties it.
        return SyncedCounts(profiles: tracker.fromAccountIDs("profiles").count, passwords: secrets.count,
                            keys: local.syncedKeyCount)
    }

    /// Deletes what came from the account from this Mac only (nothing is uploaded). Works from
    /// the change tracker, so it also works after a relaunch with no sync yet.
    public func removeSyncedData() {
        let tracker = loadState().tracker
        local.remove(profileIDs: Set(tracker.fromAccountIDs("profiles")), groupIDs: Set(tracker.fromAccountIDs("groups")),
                     secretIDs: tracker.fromAccountIDs("secrets"))
        try? FileManager.default.removeItem(at: stateFile)
        revision = nil
        lastSnapshot = nil
    }
}
