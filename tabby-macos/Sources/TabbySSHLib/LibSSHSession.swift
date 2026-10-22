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
    private var ended = false
    private let output = OutputCoalescer()

    public init(profile: Profile, environment: Environment) {
        self.profile = profile
        options = SSHOptions(profile.options)
        self.environment = environment
    }

    public func start(cols: Int, rows: Int) throws {
        size = (cols, rows)
        isRunning = true
        cancelled = false
        ended = false
        let name = profile.name.isEmpty ? options.suggestedName : profile.name
        onStatus?(.connecting("Connecting to \(name)"))
        serviceMessage("Connecting to \(name)")
        let connection = SSHConnection(options: connectionOptions(), prompter: SessionPrompter(self), passwords: environment.passwords)
        self.connection = connection
        connection.onDisconnect = { [weak self] _ in
            DispatchQueue.main.async { self?.connectionEnded() }
        }
        Task { @MainActor in
            do {
                try await connection.connect()
                guard !self.cancelled else { return connection.disconnect() }
                let handlers = SSHChannelHandlers(
                    data: { [output, weak self] chunk in
                        output.append(chunk) { data in self?.onOutput?(data) }
                    },
                    closed: { [weak self] status in
                        DispatchQueue.main.async { self?.shellClosed(status: status) }
                    })
                let shell = try await connection.openShell(term: self.options.term, columns: self.size.columns, rows: self.size.rows,
                                                           handlers: handlers, forwardAgent: self.options.agentForward)
                self.shell = shell
                guard !self.cancelled else { return shell.close() }
                self.onStatus?(.connected)
                if let cwd = self.options.cwd {
                    shell.write(Data(" cd -- '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))'\r".utf8))
                }
            } catch {
                self.fail(error)
            }
        }
    }

    func connectionOptions() -> SSHConnectionOptions {
        var o = SSHConnectionOptions(host: options.host, port: options.port, user: options.user, knownHostsFile: environment.knownHostsFile)
        o.auth = options.auth
        o.privateKeys = options.privateKeys
        o.profilePassword = options.password
        o.globalKnownHostsFile = environment.globalKnownHostsFile
        o.verifyHostKeys = environment.verifyHostKeys
        if options.auth == nil || options.auth == .agent { o.agentSocket = environment.agentSocket() }
        o.homeDirectory = environment.homeDirectory
        o.syncedKeys = environment.syncedKeys()
        if let ms = options.readyTimeout, ms > 0 { o.connectTimeout = TimeInterval(ms) / 1000 }
        o.keepaliveInterval = (TimeInterval(options.keepaliveInterval) / 1000).rounded()
        o.algorithms = options.algorithms
        o.proxyCommand = options.proxyCommand
        o.skipBanner = options.skipBanner
        return o
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
        shell?.close()
        connection?.disconnect()
    }

    public func workingDirectory() -> String? { nil }

    // MARK: Ending

    private func shellClosed(status: Int32?) {
        guard !ended else { return }
        serviceMessage("\(options.host): session closed")
        end(status)
        connection?.disconnect()
    }

    private func connectionEnded() {
        guard !ended, shell != nil else { return }
        serviceMessage("\(options.host): connection lost")
        end(nil)
    }

    private func fail(_ error: Error) {
        guard !ended else { return }
        if !cancelled {
            let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            onOutput?(Data("\u{1b}[0;37;41m X \u{1b}[0m \u{1b}[31m\(text)\u{1b}[0m\r\n".utf8))
        }
        connection?.disconnect()
        end(nil)
    }

    private func end(_ status: Int32?) {
        ended = true
        isRunning = false
        shell = nil
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

    nonisolated init(_ session: LibSSHSession) {
        self.session = session
    }

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
    public var environment: LibSSHSession.Environment
    public weak var ui: SSHSessionUI?

    public init(environment: LibSSHSession.Environment) {
        self.environment = environment
    }

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        let session = LibSSHSession(profile: profile, environment: environment)
        session.ui = ui
        return session
    }
}
#endif
