#if canImport(AppKit)
import AppKit
import Observation
import TabbyCore
import TabbySSH
import TabbyAccount
import TabbySyncProtocol

/// The personal account in the app: who is signed in, the sync status for the toolbar and
/// Settings, and when to sync: at launch, a few seconds after a change here, whenever the
/// server has a newer revision (checked every minute), and on Sync now (⌘⇧S).
@MainActor
@Observable
final class AccountService {
    enum Status: Equatable {
        case signedOut
        case upToDate
        case syncing
        case failed(String)
    }

    private(set) var session: AccountSession?
    private(set) var status: Status = .signedOut
    private(set) var lastSyncAt: Date?
    private(set) var devices: [DeviceDTO] = []
    private(set) var pendingKeyFiles: [KeyFileCandidate] = []
    private(set) var counts = SyncEngine.SyncedCounts()
    /// What "Remove synced data" would delete (what came from the account).
    private(set) var removableCounts = SyncEngine.SyncedCounts()
    /// True while a new Mac applies the account for the first time (the "Welcome back" view).
    private(set) var isRestoring = false
    /// Changes made here that have not reached the server yet.
    private(set) var hasLocalChanges = false

    var isSignedIn: Bool { session != nil }

    @ObservationIgnored let local: LocalSyncData
    @ObservationIgnored let stateFile: URL
    @ObservationIgnored private let transport: HTTPTransport
    @ObservationIgnored private let baseURL: URL
    @ObservationIgnored private let persistentStore: SessionStore
    @ObservationIgnored private var store: SessionStore
    @ObservationIgnored private(set) var engine: SyncEngine?
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored private let pollInterval: TimeInterval
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var pollTimer: Timer?
    /// A change arrived while a sync was running; sync again when it ends.
    @ObservationIgnored private var changedDuringSync = false
    /// Scrypt parameters for new passwords (tests pass small ones).
    @ObservationIgnored private let kdf: KDFParams?
    /// Called after every sync with what happened (the window shows toasts).
    @ObservationIgnored var onSyncFinished: ((SyncReport?, Error?) -> Void)?

    init(local: LocalSyncData, stateFile: URL, transport: HTTPTransport, baseURL: URL, persistentStore: SessionStore,
         debounceInterval: TimeInterval = 5, pollInterval: TimeInterval = 60, kdf: KDFParams? = nil) {
        self.kdf = kdf
        self.local = local
        self.stateFile = stateFile
        self.transport = transport
        self.baseURL = baseURL
        self.persistentStore = persistentStore
        self.store = persistentStore
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
    }

    /// The app's account service: the fixed server over HTTPS, the session in the Keychain.
    /// `TABBYMAC_SYNC_URL=memory:` runs against an in-memory server, and it or
    /// `TABBYMAC_KEYCHAIN=memory` keeps the session out of the login keychain (tests, and the
    /// two-instance M7 check).
    static func standard(local: LocalSyncData, paths: ConfigPaths) -> AccountService {
        let environment = ProcessInfo.processInfo.environment
        let stateFile = paths.root.appendingPathComponent("sync-state.json")
        let store: SessionStore = usesMemoryStores(environment: environment) ? MemorySessionStore() : KeychainSessionStore()
        if environment["TABBYMAC_SYNC_URL"] == "memory:" {
            return AccountService(local: local, stateFile: stateFile, transport: InMemorySyncServer(),
                                  baseURL: URL(string: "https://memory.invalid")!, persistentStore: store)
        }
        return AccountService(local: local, stateFile: stateFile, transport: URLSessionTransport(), baseURL: SyncClient.configuredURL,
                              persistentStore: store)
    }

    static func usesMemoryStores(environment: [String: String]) -> Bool {
        environment["TABBYMAC_SYNC_URL"] == "memory:" || environment["TABBYMAC_KEYCHAIN"] == "memory"
    }

    static var deviceInfo: DeviceInfo {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return DeviceInfo(name: Host.current().localizedName ?? "Mac", model: String(cString: model),
                          os: "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)")
    }

    private func client(token: String? = nil) throws -> SyncClient {
        try SyncClient(baseURL: baseURL, transport: transport, token: token)
    }

    /// Resumes a kept session at launch.
    func start() {
        guard let saved = persistentStore.load() else { return }
        activate(saved, keepSignedIn: true)
        Task { await syncNow() }
    }

    private func activate(_ s: AccountSession, keepSignedIn: Bool) {
        store = keepSignedIn ? persistentStore : MemorySessionStore()
        if !keepSignedIn { persistentStore.clear() }
        store.save(s)
        session = s
        engine = (try? client(token: s.token)).map { SyncEngine(client: $0, session: s, local: local, stateFile: stateFile) }
        status = .upToDate
        startPolling()
    }

    // MARK: Signing in and out

    /// Step 1 of creating an account. The first upload waits for `finishRegistration()`, after
    /// the recovery key has been saved.
    func register(email: String, password: String, keepSignedIn: Bool) async throws -> RecoveryKey {
        let (s, recovery) = try await AccountFlows.register(client: try client(), email: email, password: password, device: Self.deviceInfo,
                                                            kdf: kdf ?? .generate())
        try? FileManager.default.removeItem(at: stateFile)
        activate(s, keepSignedIn: keepSignedIn)
        return recovery
    }

    func finishRegistration() async {
        await syncNow()
    }

    func signIn(email: String, password: String, keepSignedIn: Bool) async throws {
        let s = try await AccountFlows.signIn(client: try client(), email: email, password: password, device: Self.deviceInfo)
        backUpConfigBeforeSignIn()
        try? FileManager.default.removeItem(at: stateFile)
        activate(s, keepSignedIn: keepSignedIn)
        isRestoring = true
        await syncNow()
        isRestoring = false
    }

    func recover(email: String, recoveryKey: String, newPassword: String, keepSignedIn: Bool) async throws {
        let key = try RecoveryKey(parsing: recoveryKey)
        let s = try await AccountFlows.recover(client: try client(), email: email, recoveryKey: key, newPassword: newPassword,
                                               device: Self.deviceInfo, kdf: kdf ?? .generate())
        backUpConfigBeforeSignIn()
        try? FileManager.default.removeItem(at: stateFile)
        activate(s, keepSignedIn: keepSignedIn)
        isRestoring = true
        await syncNow()
        isRestoring = false
    }

    /// The first sync of a signed-in Mac takes the account's settings; keep what was here
    /// (`config.yaml.before-sign-in`, replaced at each sign-in) so it can be restored by hand.
    private func backUpConfigBeforeSignIn() {
        guard let text = try? local.config.serializedUserConfig() else { return }
        let url = stateFile.deletingLastPathComponent().appendingPathComponent("config.yaml.before-sign-in")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Signs out here. With `removeSyncedData`, what came from the account is deleted from this
    /// Mac only; otherwise it stays, unsynced.
    func signOut(removeSyncedData: Bool) async {
        guard let engine else { return }
        // An in-flight sync must not write anything after this point.
        engine.cancel()
        if removeSyncedData { engine.removeSyncedData() }
        endSession()
        try? await engine.client.signOut()
    }

    private func endSession() {
        engine?.cancel()
        persistentStore.clear()
        store.clear()
        pollTimer?.invalidate()
        pollTimer = nil
        debounce?.cancel()
        engine = nil
        session = nil
        devices = []
        pendingKeyFiles = []
        counts = SyncEngine.SyncedCounts()
        removableCounts = SyncEngine.SyncedCounts()
        lastSyncAt = nil
        hasLocalChanges = false
        status = .signedOut
        try? FileManager.default.removeItem(at: stateFile)
    }

    // MARK: Syncing

    func syncNow() async {
        guard let engine, status != .syncing else { return }
        debounce?.cancel()
        changedDuringSync = false
        status = .syncing
        do {
            let report = try await engine.sync()
            // Signed out (or in again) while this sync ran: its result belongs to nobody.
            guard self.engine === engine else { return }
            pendingKeyFiles = report.pendingKeyFiles
            counts = engine.syncedCounts
            removableCounts = engine.removableCounts
            lastSyncAt = Date()
            hasLocalChanges = false
            if engine.session != session, let s = Optional(engine.session) {
                session = s
                store.save(s)
            }
            status = .upToDate
            onSyncFinished?(report, nil)
            if changedDuringSync {
                changedDuringSync = false
                localDataChanged()
            }
        } catch is CancellationError {
            return
        } catch let error as SyncClientError where error.code == ErrorDTO.Code.unauthorized {
            guard self.engine === engine else { return }
            // The device was removed from another Mac, or the account was deleted.
            endSession()
            status = .failed(error.localizedDescription)
            onSyncFinished?(nil, error)
        } catch {
            guard self.engine === engine else { return }
            status = .failed(error.localizedDescription)
            onSyncFinished?(nil, error)
        }
    }

    /// A change here (config, Keychain): sync a few seconds later, unless it came from a sync.
    func localDataChanged() {
        guard engine != nil else { return }
        hasLocalChanges = true
        guard status != .syncing else {
            changedDuringSync = true
            return
        }
        guard local.config.value("account.auto")?.boolValue ?? true else { return }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.syncNow() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.engine, self.status != .syncing else { return }
                // Retry a failed sync and push changes that are still waiting; otherwise only
                // sync when another Mac uploaded.
                if case .failed = self.status {
                    await self.syncNow()
                } else if self.hasLocalChanges {
                    await self.syncNow()
                } else if (try? await engine.remoteHasChanged()) == true {
                    await self.syncNow()
                }
            }
        }
    }

    /// The user's answer for key files offered for upload.
    func decideKeyFiles(approve: [String], decline: [String]) {
        let config = local.config
        let approved = Set(config.value("account.approvedKeyFiles")?.stringArrayValue ?? []).union(approve)
        let declined = Set(config.value("account.declinedKeyFiles")?.stringArrayValue ?? []).union(decline).subtracting(approve)
        config.set("account.approvedKeyFiles", .array(approved.sorted().map { .string($0) }))
        config.set("account.declinedKeyFiles", .array(declined.sorted().map { .string($0) }))
        pendingKeyFiles.removeAll { approve.contains($0.id) || decline.contains($0.id) }
        Task { await syncNow() }
    }

    // MARK: Account management

    func refreshDevices() async {
        guard let engine else { return }
        devices = (try? await engine.client.devices()) ?? devices
    }

    func removeDevice(_ id: UUID) async throws {
        guard let engine else { return }
        try await engine.client.removeDevice(id)
        await refreshDevices()
    }

    func changePassword(old: String, new: String) async throws {
        guard let engine, let session else { return }
        try await AccountFlows.changePassword(client: engine.client, email: session.email, oldPassword: old, newPassword: new)
    }

    /// The recovery key, after the password has been checked.
    func revealRecoveryKey(password: String) async throws -> String? {
        guard let engine else { return nil }
        guard try await AccountFlows.verifyPassword(client: engine.client, password: password) else {
            throw SyncClientError.server(status: 401, code: ErrorDTO.Code.invalidCredentials, message: "")
        }
        return session?.recoveryKey
    }

    func regenerateRecoveryKey(password: String) async throws -> RecoveryKey {
        guard let engine, let session else { throw SyncClientError.invalidResponse }
        let key = try await AccountFlows.rotateRecoveryKey(client: engine.client, session: session, password: password)
        engine.setRecoveryKey(key.displayString)
        self.session = engine.session
        store.save(engine.session)
        await syncNow()
        return key
    }

    func deleteAccount(password: String) async throws {
        guard let engine else { return }
        try await AccountFlows.deleteAccount(client: engine.client, password: password)
        endSession()
    }
}
#endif
