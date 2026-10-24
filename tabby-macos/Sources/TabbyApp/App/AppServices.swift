#if canImport(AppKit)
import AppKit
import Observation
import TabbyCore
import TabbyTerminal
import TabbySSH
import TabbySSHLib
import TabbyTelnet
import TabbySerial
import TabbyAccount

/// Process-wide services: configuration, profiles, sessions, theme. Replaces the Angular
/// root injector of Tabby.
@MainActor
@Observable
public final class AppServices {
    public static let shared = AppServices()

    @ObservationIgnored public let paths: ConfigPaths
    @ObservationIgnored public let config: ConfigStore
    @ObservationIgnored public let configFile: ConfigFile
    @ObservationIgnored public let profiles: ProfileRegistry
    @ObservationIgnored public let schemes: ColorSchemeCatalog
    @ObservationIgnored public let recovery: RecoveryStore
    @ObservationIgnored public let askpass: AskpassServer
    @ObservationIgnored public let passwords: PasswordStore
    /// Private keys that arrived through sync (`<config>/keys`).
    @ObservationIgnored public let keyFiles: KeyFileStore
    @ObservationIgnored public private(set) var factories: [String: SessionFactory] = [:]
    @ObservationIgnored public let sshFactory: SSHSessionFactory
    /// The library (libssh) backend; `ssh.backend: openssh` or a profile's `backend` picks
    /// `sshFactory` instead.
    @ObservationIgnored let libSSHFactory: LibSSHSessionFactory
    /// Serial ports on this Mac, kept current as devices come and go.
    @ObservationIgnored public let serialPorts: SerialPortList
    public let theme: ThemeManager
    let account: AccountService

    /// Bumped on every config change so SwiftUI views can depend on it.
    public private(set) var configRevision = 0
    /// Set when config.yaml could not be parsed at launch.
    public private(set) var loadError: String?
    /// The language the interface shows (`language`, or the system's when that is null);
    /// `nil` is English. Changing it reloads the catalogs and posts `languageDidChange`.
    public private(set) var language: String?
    public static let languageDidChange = Notification.Name("TabbyMacLanguageDidChange")

    @ObservationIgnored private var saveWork: DispatchWorkItem?

    private init() {
        paths = ConfigPaths.standard()
        try? paths.ensureExists()
        configFile = ConfigFile(paths: paths)
        let defaults = (try? ConfigStore.bundledDefaults()) ?? .emptyObject
        var user: ConfigValue = .emptyObject
        var error: String?
        do { user = try configFile.load() } catch let e { error = e.localizedDescription }
        config = ConfigStore(defaults: defaults, user: user)
        schemes = ColorSchemeCatalog()
        recovery = RecoveryStore(url: paths.recoveryFile)
        askpass = AskpassServer(socketPath: AskpassServer.defaultSocketPath())
        // Tests set TABBYMAC_KEYCHAIN=memory: syncing reads every saved SSH password, and in a
        // test run that must never reach the user's login keychain (or raise its prompt).
        let keychain: PasswordStore = ProcessInfo.processInfo.environment["TABBYMAC_KEYCHAIN"] == "memory"
            ? InMemoryPasswordStore() : KeychainPasswordStore()
        let notifyingPasswords = NotifyingPasswordStore(keychain)
        passwords = notifyingPasswords
        keyFiles = KeyFileStore(directory: paths.root.appendingPathComponent("keys", isDirectory: true))
        theme = ThemeManager()

        let recents = RecentProfilesStore(url: paths.recentProfilesFile)
        var shellCache: [Shell]?
        let local = LocalProfileProvider(shells: {
            if shellCache == nil { shellCache = ShellDetector.detectShells() }
            return shellCache ?? []
        })
        let ssh = SSHProfileProvider(sshConfig: {
            try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8)
        })
        let serialPorts = SerialPortList()
        self.serialPorts = serialPorts
        let serial = SerialProfileProvider(ports: { MainActor.assumeIsolated { serialPorts.ports } })
        profiles = ProfileRegistry(config: config, providers: [local, ssh, serial, TelnetProfileProvider()], recents: recents)

        let askpassPath = Self.askpassExecutablePath()
        sshFactory = SSHSessionFactory(
            environment: SSHSession.Environment(
                askpassPath: askpassPath,
                server: askpass,
                passwords: passwords,
                knownHostsFile: paths.knownHostsFile.path,
                verifyHostKeys: config.value("ssh.verifyHostKeys")?.boolValue ?? true
            ),
            resolveProfile: { _ in nil }
        )
        let keyFiles = keyFiles
        sshFactory.environment.syncedKeys = { keyFiles.syncedKeys() }
        account = AccountService.standard(
            local: LocalSyncData(config: config, passwords: notifyingPasswords, keyStore: keyFiles, knownHostsFile: paths.knownHostsFile,
                                 // Tests point this at a scratch folder so no real ~/.ssh key is read.
                                 homeDirectory: ProcessInfo.processInfo.environment["TABBYMAC_SYNC_HOME"] ?? NSHomeDirectory()),
            paths: paths)
        let config = config
        libSSHFactory = LibSSHSessionFactory(environment: LibSSHSession.Environment(
            knownHostsFile: paths.knownHostsFile.path,
            verifyHostKeys: config.value("ssh.verifyHostKeys")?.boolValue ?? true,
            agentSocket: {
                let configured = MainActor.assumeIsolated { config.value("ssh.agentPath")?.stringValue }
                if let configured, !configured.isEmpty { return (configured as NSString).expandingTildeInPath }
                return ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
            },
            syncedKeys: { keyFiles.syncedKeys() },
            passwords: passwords))
        libSSHFactory.environment.x11Display = {
            MainActor.assumeIsolated { config.value("ssh.x11Display")?.stringValue }.flatMap { $0.isEmpty ? nil : $0 }
        }
        factories["local"] = LocalSessionFactory()
        factories["telnet"] = TelnetSessionFactory()
        factories["serial"] = SerialSessionFactory()
        factories["ssh"] = SSHBackendFactory(openSSH: sshFactory, library: libSSHFactory,
                                             configuredBackend: { MainActor.assumeIsolated { config.value("ssh.backend")?.stringValue } })
        loadError = error

        config.observe { [weak self] in
            MainActor.assumeIsolated { self?.configChanged() }
        }
        let account = account
        notifyingPasswords.onChange = { MainActor.assumeIsolated { account.localDataChanged() } }
        theme.update(config: config)
        language = Self.resolveLanguage(config)
        L10n.load(language: language)
    }

    /// The system's preferred languages; `TABBYMAC_PREFERRED_LANGUAGES` (comma-separated)
    /// replaces them so tests run in English on any Mac.
    static func preferredLanguages() -> [String] {
        if let pinned = ProcessInfo.processInfo.environment["TABBYMAC_PREFERRED_LANGUAGES"] {
            return pinned.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return Locale.preferredLanguages
    }

    static func resolveLanguage(_ config: ConfigStore) -> String? {
        Languages.resolve(configured: config.string("language"), preferred: preferredLanguages())
    }

    /// ★ Applies live: SwiftUI views re-render through `configRevision` and the menu bar is
    /// rebuilt; text already printed in terminals stays as it was.
    private func languageMayHaveChanged() {
        let resolved = Self.resolveLanguage(config)
        guard resolved != language else { return }
        language = resolved
        L10n.load(language: resolved)
        NotificationCenter.default.post(name: Self.languageDidChange, object: self)
    }

    /// Call once at launch, after `shared` exists.
    public func start() {
        // Jump hosts are resolved through the registry (needs `self`, so wired after init).
        let registry = profiles
        sshFactory.resolveProfile = { id in registry.profile(withId: id).map { registry.resolved($0) } }
        libSSHFactory.connector.resolveProfile = { id in registry.profile(withId: id).map { registry.resolved($0) } }
        do { try askpass.start() } catch { NSLog("TabbyMac: askpass server failed: \(error)") }
        // Like Tabby, make sure config.yaml exists after the first launch so users can find
        // and edit it, even before they change a setting.
        if loadError == nil, !FileManager.default.fileExists(atPath: paths.configFile.path) { flushSave() }
        account.start()
    }

    public func stop() {
        flushPendingSave()
        askpass.stop()
    }

    static func askpassExecutablePath() -> String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "tabby-askpass") { return url.path }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tabby-askpass")
        return sibling.path
    }

    // MARK: Config

    private func configChanged() {
        languageMayHaveChanged()
        configRevision += 1
        theme.update(config: config)
        sshFactory.environment.verifyHostKeys = config.value("ssh.verifyHostKeys")?.boolValue ?? true
        libSSHFactory.environment.verifyHostKeys = sshFactory.environment.verifyHostKeys
        scheduleSave()
        account.localDataChanged()
    }

    public func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Quitting: writes only a change still waiting to be saved, so a hand edit of config.yaml
    /// made while the app ran is not overwritten (found in the M8 walk).
    public func flushPendingSave() {
        guard saveWork != nil else { return }
        flushSave()
    }

    public func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        do { try configFile.save(config) } catch { NSLog("TabbyMac: could not save config: \(error)") }
    }

    /// Replaces the user config with Electron Tabby's config.yaml.
    public func importElectronTabbyConfig() throws -> Bool {
        guard let value = try ConfigFile.loadElectronTabbyConfig() else { return false }
        try config.replaceUser(value)
        flushSave()
        return true
    }

    // MARK: Sessions

    public func factory(for profile: Profile) -> SessionFactory? {
        factories[profile.type]
    }

    public var terminalSettings: TerminalSettings { TerminalSettings(config: config) }

    public func sessionContext(cwd: String?) -> SessionContext {
        SessionContext(workingDirectory: cwd, environment: terminalSettings.environment)
    }

    /// The default profile for new tabs (`terminal.profile`, falling back to the first
    /// built-in local profile, as `tabby-local/src/services/terminal.service.ts` does).
    public func defaultProfile() -> Profile {
        let id = config.string("terminal.profile") ?? "local:default"
        if let p = profiles.profile(withId: id) { return profiles.resolved(p) }
        if let p = profiles.builtinProfiles().first(where: { $0.type == "local" }) { return profiles.resolved(p) }
        return Profile(id: "local:default", type: "local", name: L("Shell"), options: LocalOptions(command: "").configValue)
    }
}
#endif
