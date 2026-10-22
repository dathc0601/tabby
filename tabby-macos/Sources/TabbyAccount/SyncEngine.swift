import Crypto
import Foundation
import TabbyCore
import TabbySyncProtocol

public struct SyncReport: Equatable, Sendable {
    /// A new vault revision was uploaded.
    public var uploaded = false
    /// Changes from other Macs were written to this one.
    public var applied = false
    /// Key files waiting for the user's yes or no before they upload.
    public var pendingKeyFiles: [KeyFileCandidate] = []
}

public enum SyncEngineError: Error, LocalizedError {
    case tooManyConflicts

    public var errorDescription: String? {
        "Another Mac kept changing the account while this one synced. Try again in a moment."
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

    public func sync() async throws -> SyncReport {
        let key = try VaultCrypto.encryptionKey(from: session.encryptionKey)
        for _ in 0..<4 {
            var report = SyncReport()
            let parts = SyncParts(config: local.config)
            let collected = local.collect(recoveryKey: session.recoveryKey)
            report.pendingKeyFiles = collected.pendingKeyFiles
            var state = loadState()
            let time = now()
            var mine = SyncSnapshot(
                createdAt: time, deviceId: session.deviceID.uuidString,
                settings: state.tracker.observeText("settings", text: collected.settings, now: time),
                profiles: state.tracker.observe("profiles", items: collected.profiles, now: time),
                groups: state.tracker.observe("groups", items: collected.groups, now: time),
                secrets: state.tracker.observe("secrets", items: collected.secrets, now: time),
                keyFiles: state.tracker.observe("keyFiles", items: collected.keyFiles, now: time),
                knownHosts: state.tracker.observeText("knownHosts", text: collected.knownHosts, now: time))

            let remote = try await client.vault()
            var merged = mine
            var changedLocally = false
            var needsUpload = true
            if let remote {
                let theirs = try VaultCrypto.openSnapshot(remote.ciphertext, using: key)
                // Parts that are off here: keep the server's copy and leave this Mac alone.
                if !parts.profiles { mine.profiles = theirs.profiles; mine.groups = theirs.groups }
                if !parts.secrets { mine.secrets = theirs.secrets; mine.keyFiles = theirs.keyFiles }
                if !parts.knownHosts { mine.knownHosts = theirs.knownHosts }
                if !parts.settings { mine.settings = theirs.settings }
                // A Mac's first sync with an existing account restores the account's settings
                // (the design's "Welcome back"); its own were never edited "after" them.
                if state.revision == nil, theirs.settings != nil { mine.settings = theirs.settings }
                let result = SyncMerger.merge(local: mine, remote: theirs, now: time)
                merged = result.snapshot
                changedLocally = result.changedLocally
                needsUpload = result.needsUpload
                // known_hosts entries only accumulate: keep the lines of both sides.
                if parts.knownHosts, let ours = mine.knownHosts?.text, let other = theirs.knownHosts?.text {
                    let union = Self.unionLines(ours, other)
                    if union != merged.knownHosts?.text {
                        merged.knownHosts = TextSection(updatedAt: time, text: union)
                    }
                    changedLocally = changedLocally || union != ours
                    needsUpload = needsUpload || union != other
                }
            }

            if changedLocally {
                local.apply(merged, over: collected, parts: parts)
                report.applied = true
            }
            state.tracker.adopt("profiles", merged.profiles)
            state.tracker.adopt("groups", merged.groups)
            state.tracker.adopt("secrets", merged.secrets)
            state.tracker.adopt("keyFiles", merged.keyFiles)
            state.tracker.adoptText("settings", merged.settings)
            state.tracker.adoptText("knownHosts", merged.knownHosts)

            if needsUpload {
                let blob = try VaultCrypto.sealSnapshot(merged, using: key)
                switch try await client.putVault(blob, ifMatch: remote?.revision ?? 0) {
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
            learnRecoveryKey(from: merged)
            return report
        }
        throw SyncEngineError.tooManyConflicts
    }

    private func learnRecoveryKey(from snapshot: SyncSnapshot) {
        guard session.recoveryKey == nil,
              let item = snapshot.secrets.items.first(where: { $0.id == "account:recovery-key" }),
              let value = item.value["value"]?.stringValue else { return }
        session.recoveryKey = value
    }

    /// After a recovery key rotation.
    public func setRecoveryKey(_ key: String) {
        session.recoveryKey = key
    }

    static func unionLines(_ a: String, _ b: String) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for line in (a + "\n" + b).split(separator: "\n", omittingEmptySubsequences: true).map(String.init) where !seen.contains(line) {
            seen.insert(line)
            lines.append(line)
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    // MARK: Signing out

    public struct SyncedCounts: Equatable, Sendable {
        public var profiles = 0
        public var passwords = 0
        public var keys = 0
    }

    /// What came from the account, for the sign-out choice ("Deletes 23 profiles, 6 passwords
    /// and 3 keys from this Mac only").
    public var syncedCounts: SyncedCounts {
        guard let s = lastSnapshot else { return SyncedCounts() }
        let passwords = s.secrets.items.filter { ["ssh:password", "ssh:key-passphrase"].contains($0.value["type"]?.stringValue ?? "") }
        return SyncedCounts(profiles: s.profiles.items.count, passwords: passwords.count, keys: s.keyFiles.items.count)
    }

    /// Deletes what came from the account from this Mac only (nothing is uploaded).
    public func removeSyncedData() {
        if let lastSnapshot { local.remove(lastSnapshot) }
        try? FileManager.default.removeItem(at: stateFile)
        revision = nil
        lastSnapshot = nil
    }
}
