#if os(macOS)
import Foundation
import TabbyCore
import TabbySSH
import TabbyTerminal

/// The app's sheets and panels for a session's questions (host key card, password and
/// passphrase cards, the keyboard-interactive panel). Implemented in TabbyApp.
@MainActor
public protocol SSHSessionUI: AnyObject {
    func verifyHostKey(_ request: HostKeyRequest, for session: LibSSHSession) async -> HostKeyDecision
    func password(user: String, host: String, for session: LibSSHSession) async -> SecretAnswer?
    func passphrase(keyPath: String, for session: LibSSHSession) async -> SecretAnswer?
    func keyboardInteractive(_ round: KeyboardInteractiveRound, for session: LibSSHSession) async -> KeyboardInteractiveAnswer?
    func username(host: String, for session: LibSSHSession) async -> String?
    /// A toast on the session's window (e.g. a forward that could not start).
    func notify(title: String, detail: String, isError: Bool, for session: LibSSHSession)
    /// The session ended or its tab closed: questions and panels for it go away.
    func sessionEnded(_ session: LibSSHSession)
}

public extension SSHSessionUI {
    func notify(title: String, detail: String, isError: Bool, for session: LibSSHSession) {}
    func sessionEnded(_ session: LibSSHSession) {}
}

/// An SSH terminal session on the library backend: one shell channel on an `SSHConnection`.
public final class LibSSHSession: TerminalSession {
    /// What every session shares: files, the Keychain, the agent, synced keys.
    public struct Environment {
        public var knownHostsFile: String
        public var globalKnownHostsFile: String?
        public var verifyHostKeys: Bool
        /// The agent socket to use (`ssh.agentPath` or `SSH_AUTH_SOCK`), nil for none.
        public var agentSocket: () -> String?
        public var homeDirectory: String
        public var syncedKeys: () -> SyncedKeys
        public var passwords: PasswordStore
        /// `ssh.x11Display`; nil uses `$DISPLAY`.
        public var x11Display: () -> String? = { nil }

        public init(knownHostsFile: String, globalKnownHostsFile: String? = NSHomeDirectory() + "/.ssh/known_hosts",
                    verifyHostKeys: Bool = true,
                    agentSocket: @escaping () -> String? = { ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] },
                    homeDirectory: String = NSHomeDirectory(), syncedKeys: @escaping () -> SyncedKeys = { .none },
                    passwords: PasswordStore) {
            self.knownHostsFile = knownHostsFile
            self.globalKnownHostsFile = globalKnownHostsFile
            self.verifyHostKeys = verifyHostKeys
            self.agentSocket = agentSocket
            self.homeDirectory = homeDirectory
            self.syncedKeys = syncedKeys
            self.passwords = passwords
        }
    }

    public var onOutput: ((Data) -> Void)?
    public var onClosed: ((Int32?) -> Void)?
    public var onStatus: ((SessionStatus) -> Void)?

    public let profile: Profile
    public let options: SSHOptions
    let environment: Environment
    public weak var ui: SSHSessionUI?

    public private(set) var isRunning = false
    public private(set) var connection: SSHConnection?
    private var shell: SSHShellChannel?
    private var size = (columns: 80, rows: 24)
    private var cancelled = false
    /// Abandons this session's unanswered questions when it is killed.
    private var cancelFlag = CancelFlag()
    private var ended = false
    private let output = OutputCoalescer()

    /// Shares connections between sessions (the factory's); a session made on its own gets
    /// its own connector when it starts.
    var connector: SSHConnector?

    public init(profile: Profile, environment: Environment, connector: SSHConnector? = nil) {
        self.profile = profile
        options = SSHOptions(profile.options)
        self.environment = environment
        self.connector = connector
    }

    public func start(cols: Int, rows: Int) throws {
        size = (cols, rows)
        isRunning = true
        cancelled = false
        ended = false
        let name = profile.name.isEmpty ? options.suggestedName : profile.name
        onStatus?(.connecting("Connecting to \(name)"))
        serviceMessage("Connecting to \(name)")
        let connector = MainActor.assumeIsolated { self.connector ?? SSHConnector(environment: environment) }
        self.connector = connector
        let profile = profile
        let flag = CancelFlag()
        cancelFlag = flag
        Task { @MainActor in
            do {
                let connection = try await connector.acquire(profile: profile, prompter: SessionPrompter(self, cancel: flag))
                self.connection = connection
                guard !self.cancelled else { return self.releaseConnection() }
                let handlers = SSHChannelHandlers(
                    data: { [output, weak self] chunk in
                        output.append(chunk) { data in self?.onOutput?(data) }
                    },
                    closed: { [weak self] status in
                        DispatchQueue.main.async { self?.shellClosed(status: status) }
                    })
                let shell = try await connection.openShell(term: self.options.term, columns: self.size.columns, rows: self.size.rows,
                                                           handlers: handlers, forwardAgent: self.options.agentForward,
                                                           forwardX11: self.options.x11)
                self.shell = shell
                guard !self.cancelled else { return shell.close() }
                self.onStatus?(.connected)
                if let cwd = self.options.cwd {
                    shell.write(Data(" cd -- '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))'\r".utf8))
                }
                await self.startProfileForwards(on: connection)
            } catch {
                self.fail(error)
            }
        }
    }

    func connectionOptions() -> SSHConnectionOptions {
        Self.connectionOptions(for: options, environment: environment)
    }

    public static func connectionOptions(for options: SSHOptions, environment: Environment) -> SSHConnectionOptions {
        var o = SSHConnectionOptions(host: options.host, port: options.port, user: options.user, knownHostsFile: environment.knownHostsFile)
        o.auth = options.auth
        o.privateKeys = options.privateKeys
        o.profilePassword = options.password
        o.globalKnownHostsFile = environment.globalKnownHostsFile
        o.verifyHostKeys = environment.verifyHostKeys
        // Forwarding needs the agent even when it is not used to log in.
        if options.auth == nil || options.auth == .agent || options.agentForward { o.agentSocket = environment.agentSocket() }
        o.x11Display = environment.x11Display()
        o.homeDirectory = environment.homeDirectory
        o.syncedKeys = environment.syncedKeys()
        if let ms = options.readyTimeout, ms > 0 { o.connectTimeout = TimeInterval(ms) / 1000 }
        o.keepaliveInterval = (TimeInterval(options.keepaliveInterval) / 1000).rounded()
        o.algorithms = options.algorithms
        o.proxyCommand = options.proxyCommand
        if let host = options.socksProxyHost {
            o.proxy = .socks5(host: host, port: options.socksProxyPort ?? 1080)
        } else if let host = options.httpProxyHost {
            o.proxy = .http(host: host, port: options.httpProxyPort ?? 8080)
        }
        o.skipBanner = options.skipBanner
        return o
    }

    /// The profile's saved forwards (those a shared connection does not already run). One
    /// that fails is reported; the session carries on (OpenSSH's ExitOnForwardFailure no).
    @MainActor
    private func startProfileForwards(on connection: SSHConnection) async {
        for forward in options.forwardedPorts where !connection.forwards.contains(where: { $0.forward == forward }) {
            do {
                _ = try await connection.addForward(forward)
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                serviceMessage(text)
                ui?.notify(title: "Failed to forward port", detail: text.replacingOccurrences(of: "Failed to forward port ", with: ""),
                           isError: true, for: self)
            }
        }
    }

    public func write(_ data: Data) {
        shell?.write(data)
    }

    public func resize(cols: Int, rows: Int) {
        size = (cols, rows)
        shell?.resize(columns: cols, rows: rows)
    }

    public func kill() {
        cancelled = true
        cancelFlag.set()
        MainActor.assumeIsolated { ui?.sessionEnded(self) }
        shell?.close()
        // Released here, not when the close is reported: the pane lets go of this session
        // right after kill(), so a handler holding it weakly would never run.
        releaseConnection()
    }

    /// Gives the connection back to the connector (it closes with its last session).
    private func releaseConnection() {
        guard let connection else { return }
        self.connection = nil
        MainActor.assumeIsolated { connector?.release(connection) }
    }

    public func workingDirectory() -> String? { nil }

    // MARK: Ending

    private func shellClosed(status: Int32?) {
        guard !ended else { return }
        serviceMessage("\(options.host): session closed")
        end(status)
        releaseConnection()
    }

    private func fail(_ error: Error) {
        guard !ended else { return }
        if !cancelled {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            onOutput?(Data("\u{1b}[0;37;41m X \u{1b}[0m \u{1b}[31m\(text)\u{1b}[0m\r\n".utf8))
        }
        releaseConnection()
        end(nil)
    }

    private func end(_ status: Int32?) {
        ended = true
        isRunning = false
        shell = nil
        MainActor.assumeIsolated { ui?.sessionEnded(self) }
        onStatus?(.disconnected)
        onClosed?(status)
    }

    /// A Tabby-style service line: an inverse ` SSH ` badge and the text.
    func serviceMessage(_ text: String) {
        onOutput?(Data("\u{1b}[0;30;46m SSH \u{1b}[0m \(text.replacingOccurrences(of: "\n", with: "\r\n      "))\r\n".utf8))
    }
}

/// Forwards a connection's questions to the session's UI and its messages to its terminal.
@MainActor
final class SessionPrompter: SSHConnectionPrompter {
    private weak var session: LibSSHSession?
    private let cancel: CancelFlag

    init(_ session: LibSSHSession, cancel: CancelFlag) {
        self.session = session
        self.cancel = cancel
    }

    nonisolated var isCancelled: Bool { cancel.isSet }

    func verifyHostKey(_ request: HostKeyRequest) async -> HostKeyDecision {
        guard let session, let ui = session.ui else { return .reject }
        return await ui.verifyHostKey(request, for: session)
    }

    func password(user: String, host: String) async -> SecretAnswer? {
        guard let session, let ui = session.ui else { return nil }
        return await ui.password(user: user, host: host, for: session)
    }

    func passphrase(keyPath: String) async -> SecretAnswer? {
        guard let session, let ui = session.ui else { return nil }
        return await ui.passphrase(keyPath: keyPath, for: session)
    }

    func keyboardInteractive(_ round: KeyboardInteractiveRound) async -> KeyboardInteractiveAnswer? {
        guard let session, let ui = session.ui else { return nil }
        return await ui.keyboardInteractive(round, for: session)
    }

    func username(host: String) async -> String? {
        guard let session, let ui = session.ui else { return nil }
        return await ui.username(host: host, for: session)
    }

    func message(_ text: String) {
        session?.serviceMessage(text)
    }
}

/// Moves output from the connection's thread to the main queue, one delivery at a time:
/// chunks that arrive while one is queued are joined to it.
final class OutputCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var scheduled = false

    func append(_ chunk: Data, deliver: @escaping (Data) -> Void) {
        let schedule = lock.withLock { () -> Bool in
            pending.append(chunk)
            defer { scheduled = true }
            return !scheduled
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let data = lock.withLock { () -> Data in
                defer { pending = Data(); scheduled = false }
                return pending
            }
            if !data.isEmpty { deliver(data) }
        }
    }
}

/// Creates library-backend SSH sessions.
public final class LibSSHSessionFactory: SessionFactory {
    public let profileType = "ssh"
    public var environment: LibSSHSession.Environment {
        didSet { MainActor.assumeIsolated { connector.environment = environment } }
    }
    public weak var ui: SSHSessionUI?
    /// Shared connections and jump hosts for every session of this factory.
    public let connector: SSHConnector

    public init(environment: LibSSHSession.Environment) {
        self.environment = environment
        connector = MainActor.assumeIsolated { SSHConnector(environment: environment) }
    }

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        let session = LibSSHSession(profile: profile, environment: environment, connector: connector)
        session.ui = ui
        return session
    }
}
#endif

#if os(macOS)
/// Chooses the SSH implementation per session: `ssh.backend` in config.yaml (`library`, the
/// default, or `openssh`), overridden by a profile's `backend` option.
public final class SSHBackendFactory: SessionFactory {
    public let profileType = "ssh"
    public let openSSH: SSHSessionFactory
    public let library: LibSSHSessionFactory
    public var configuredBackend: () -> String?

    public init(openSSH: SSHSessionFactory, library: LibSSHSessionFactory, configuredBackend: @escaping () -> String?) {
        self.openSSH = openSSH
        self.library = library
        self.configuredBackend = configuredBackend
    }

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        let chosen = profile.options["backend"]?.stringValue ?? configuredBackend()
        return chosen == "openssh"
            ? try openSSH.makeSession(profile: profile, context: context)
            : try library.makeSession(profile: profile, context: context)
    }
}
#endif
