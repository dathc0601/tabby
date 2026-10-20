#if canImport(AppKit)
import AppKit
import Observation
import TabbyCore
import TabbyTerminal
import TabbySSH

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
    @ObservationIgnored public private(set) var factories: [String: SessionFactory] = [:]
    @ObservationIgnored public let sshFactory: SSHSessionFactory
    public let theme: ThemeManager

    /// Bumped on every config change so SwiftUI views can depend on it.
    public private(set) var configRevision = 0
    /// Set when config.yaml could not be parsed at launch.
    public private(set) var loadError: String?

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
        passwords = KeychainPasswordStore()
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
        profiles = ProfileRegistry(config: config, providers: [local, ssh], recents: recents)

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
        factories["local"] = LocalSessionFactory()
        factories["ssh"] = sshFactory
        loadError = error

        config.observe { [weak self] in
            MainActor.assumeIsolated { self?.configChanged() }
        }
        theme.update(config: config)
    }

    /// Call once at launch, after `shared` exists.
    public func start() {
        // Jump hosts are resolved through the registry (needs `self`, so wired after init).
        let registry = profiles
        sshFactory.resolveProfile = { id in registry.profile(withId: id).map { registry.resolved($0) } }
        do { try askpass.start() } catch { NSLog("TabbyMac: askpass server failed: \(error)") }
    }

    public func stop() {
        flushSave()
        askpass.stop()
    }

    static func askpassExecutablePath() -> String {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "tabby-askpass") { return url.path }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("tabby-askpass")
        return sibling.path
    }

    // MARK: Config

    private func configChanged() {
        configRevision += 1
        theme.update(config: config)
        sshFactory.environment.verifyHostKeys = config.value("ssh.verifyHostKeys")?.boolValue ?? true
        scheduleSave()
    }

    public func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushSave() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    public func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        do { try configFile.save(config) } catch { NSLog("TabbyMac: could not save config: \(error)") }
    }

    /// Replaces the user config with Electron Tabby's config.yaml.
    public func importElectronTabbyConfig() throws -> Bool {
        guard let value = try ConfigFile.loadElectronTabbyConfig() else { return false }
        config.replaceUser(value)
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
        return Profile(id: "local:default", type: "local", name: "Shell", options: LocalOptions(command: "").configValue)
    }
}
#endif
