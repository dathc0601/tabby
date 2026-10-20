import Foundation
import TabbyCore
import TabbyTerminal
import TabbyIPC
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Replies to SSH prompts, given by the UI.
public enum SSHPromptReply: Equatable, Sendable {
    case text(String, remember: Bool)
    case accept
    case reject
    case cancel
}

/// Shows native UI for prompts the session can't answer from saved secrets.
public protocol SSHPromptHandler: AnyObject {
    func sshSession(_ session: SSHSession, needs prompt: AskpassPrompt, reply: @escaping (SSHPromptReply) -> Void)
}

/// An SSH session over the system OpenSSH client (phase-1 backend; see docs/ARCHITECTURE.md).
///
/// It writes a per-session `ssh_config` (from `SSHConfigGenerator`), runs
/// `ssh -F <config> tabby-target` in a PTY, and answers ssh's prompts through the askpass
/// bridge: saved passwords come from the `PasswordStore`, everything else goes to the
/// `SSHPromptHandler`. Behaviour mirrors `tabby-ssh/src/session/ssh.ts` where it can.
public final class SSHSession: TerminalSession {
    public struct Environment {
        public var sshPath: String
        public var askpassPath: String
        public var server: AskpassServer
        public var passwords: PasswordStore
        public var knownHostsFile: String
        public var userKnownHostsFiles: [String]
        public var verifyHostKeys: Bool
        public var configDirectory: String

        public init(sshPath: String = "/usr/bin/ssh", askpassPath: String, server: AskpassServer, passwords: PasswordStore,
                    knownHostsFile: String, userKnownHostsFiles: [String] = [NSHomeDirectory() + "/.ssh/known_hosts"],
                    verifyHostKeys: Bool = true, configDirectory: String = AskpassServer.runtimeDirectory()) {
            self.sshPath = sshPath
            self.askpassPath = askpassPath
            self.server = server
            self.passwords = passwords
            self.knownHostsFile = knownHostsFile
            self.userKnownHostsFiles = userKnownHostsFiles
            self.verifyHostKeys = verifyHostKeys
            self.configDirectory = configDirectory
        }
    }

    public var onOutput: ((Data) -> Void)?
    public var onClosed: ((Int32?) -> Void)?
    public var onStatus: ((SessionStatus) -> Void)?

    public let profile: Profile
    public let options: SSHOptions
    public weak var promptHandler: SSHPromptHandler?
    public private(set) var isConnected = false

    private let env: Environment
    private let context: SessionContext
    private let jumpHostResolver: (String) -> SSHOptions?
    private let sessionID = UUID().uuidString.lowercased()
    private let token = UUID().uuidString + UUID().uuidString
    private var process: PTYProcess?
    private var configURL: URL?
    private var passwordAttempts: [String: Int] = [:]
    /// Saves a secret the user asked to remember, once authentication succeeds.
    private var pendingSecretSave: (() -> Void)?
    private var sawHostKeyChange = false
    /// Target plus jump hosts, for matching password prompts to a port and saved password.
    private lazy var endpoints: [(user: String, host: String, port: Int, password: String?)] = {
        var list = [(options.user, options.host, options.port, options.password)]
        var seen = Set<String>()
        var next = options.jumpHost
        while let id = next, !seen.contains(id), let hop = jumpHostResolver(id) {
            seen.insert(id)
            list.append((hop.user, hop.host, hop.port, hop.password))
            next = hop.jumpHost
        }
        return list.map { (user: $0.0, host: $0.1, port: $0.2, password: $0.3) }
    }()

    public init(profile: Profile, context: SessionContext, environment: Environment, jumpHostResolver: @escaping (String) -> SSHOptions?) {
        self.profile = profile
        self.options = SSHOptions(profile.options)
        self.context = context
        self.env = environment
        self.jumpHostResolver = jumpHostResolver
    }

    deinit {
        cleanup()
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    // MARK: Lifecycle

    public func start(cols: Int, rows: Int) throws {
        let generator = SSHConfigGenerator(
            paths: .init(knownHostsFile: env.knownHostsFile, extraKnownHostsFiles: env.userKnownHostsFiles,
                         controlDirectory: env.configDirectory,
                         localCommand: "\(SSHConfigGenerator.shellQuote(env.askpassPath)) --connected"),
            verifyHostKeys: env.verifyHostKeys
        )
        let output = try generator.generate(options, jumpHostResolver: jumpHostResolver)
        let url = URL(fileURLWithPath: env.configDirectory).appendingPathComponent("ssh-\(sessionID).conf")
        try Data(output.config.utf8).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        configURL = url
        if !FileManager.default.fileExists(atPath: env.knownHostsFile) {
            try? FileManager.default.createDirectory(atPath: (env.knownHostsFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(atPath: env.knownHostsFile, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        env.server.register(session: sessionID, token: token) { [weak self] request, reply in
            guard let self else { return reply(AskpassResponse(ok: false)) }
            self.handle(request, reply: reply)
        }

        var overrides = context.environment
        overrides[AskpassEnvironment.socketKey] = env.server.socketPath
        overrides[AskpassEnvironment.sessionKey] = sessionID
        overrides[AskpassEnvironment.tokenKey] = token
        overrides["SSH_ASKPASS"] = env.askpassPath
        overrides["SSH_ASKPASS_REQUIRE"] = "force"
        if overrides["DISPLAY"] == nil { overrides["DISPLAY"] = ProcessInfo.processInfo.environment["DISPLAY"] ?? ":0" }
        let environment = SessionEnvironment.make(overrides: overrides, termName: options.term)

        serviceMessage("Connecting to \(options.host)")
        onStatus?(.connecting(options.host))
        let p = PTYProcess(executable: env.sshPath, arguments: ["-F", url.path, output.alias], environment: environment)
        p.onData = { [weak self] data in self?.handleOutput(data) }
        p.onExit = { [weak self] code in self?.handleExit(code) }
        try p.start(cols: cols, rows: rows)
        process = p
    }

    public func write(_ data: Data) { process?.write(data) }
    public func resize(cols: Int, rows: Int) { process?.resize(cols: cols, rows: rows) }

    public func kill() {
        process?.terminate()
    }

    public func workingDirectory() -> String? { nil }

    private func cleanup() {
        env.server.unregister(session: sessionID)
        if let configURL, ProcessInfo.processInfo.environment["TABBYMAC_KEEP_SSH_CONFIG"] == nil { try? FileManager.default.removeItem(at: configURL) }
        configURL = nil
    }

    private func handleOutput(_ data: Data) {
        if !sawHostKeyChange, let s = String(data: data, encoding: .utf8), s.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            sawHostKeyChange = true
        }
        onOutput?(data)
    }

    private func handleExit(_ code: Int32?) {
        cleanup()
        if sawHostKeyChange {
            serviceMessage("The host key changed. If this is expected, remove the old key with:\r\n    ssh-keygen -R \(options.host) -f \(env.knownHostsFile)")
        }
        if code == 255 && !isConnected {
            serviceMessage("Connection failed")
        }
        isConnected = false
        onStatus?(.disconnected)
        onClosed?(code)
    }

    /// Writes a Tabby-style service message: an inverse ` SSH ` badge and the text.
    private func serviceMessage(_ text: String) {
        onOutput?(Data("\u{1b}[0;30;46m SSH \u{1b}[0m \(text)\r\n".utf8))
    }

    // MARK: Prompts

    private func handle(_ request: AskpassRequest, reply: @escaping (AskpassResponse) -> Void) {
        switch request.kind {
        case .connected:
            isConnected = true
            pendingSecretSave?()
            pendingSecretSave = nil
            onStatus?(.connected)
            if let cwd = options.cwd {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.write(Data(" cd -- '\(cwd.replacingOccurrences(of: "'", with: "'\\''"))'\r".utf8))
                }
            }
            reply(AskpassResponse(ok: true))
        case .prompt:
            let prompt = AskpassPrompt.classify(request.prompt, kind: request.promptType)
            answer(prompt, reply: reply)
        }
    }

    private func answer(_ prompt: AskpassPrompt, reply: @escaping (AskpassResponse) -> Void) {
        switch prompt {
        case let .password(user, host):
            // The same user@host can appear more than once in a jump chain, and ssh's prompt
            // doesn't say which hop is asking, so allow one saved answer per matching hop.
            let key = "\(user)@\(host)"
            let attempt = passwordAttempts[key, default: 0]
            passwordAttempts[key] = attempt + 1
            let matches = endpoints.filter { $0.user == user && $0.host == host }
            let endpoint = matches.first
            let port = endpoint?.port ?? 22
            if attempt < max(matches.count, 1) {
                if let p = endpoint?.password {
                    return reply(AskpassResponse(ok: true, answer: p))
                }
                if let saved = env.passwords.password(host: host, port: port, user: user) {
                    serviceMessage("Using saved password")
                    return reply(AskpassResponse(ok: true, answer: saved))
                }
            } else if attempt == max(matches.count, 1) {
                // A saved password didn't work.
                env.passwords.deletePassword(host: host, port: port, user: user)
            }
            askUser(prompt, reply: reply) { [weak self] secret in
                guard let self else { return }
                self.pendingSecretSave = { self.env.passwords.savePassword(secret, host: host, port: port, user: user) }
            }
        case let .passphrase(keyPath):
            let keyID = Self.keyID(path: keyPath)
            let attempt = passwordAttempts["key:" + keyPath, default: 0]
            passwordAttempts["key:" + keyPath] = attempt + 1
            if attempt == 0, let keyID, let saved = env.passwords.passphrase(keyID: keyID) {
                return reply(AskpassResponse(ok: true, answer: saved))
            }
            if attempt == 1, let keyID { env.passwords.deletePassphrase(keyID: keyID) }
            askUser(prompt, reply: reply) { [weak self] secret in
                guard let self, let keyID else { return }
                self.pendingSecretSave = { self.env.passwords.savePassphrase(secret, keyID: keyID) }
            }
        case .hostKey, .confirm:
            guard let handler = promptHandler else { return reply(AskpassResponse(ok: false)) }
            handler.sshSession(self, needs: prompt) { r in
                switch r {
                case .accept: reply(AskpassResponse(ok: true, answer: "yes"))
                case .reject: reply(AskpassResponse(ok: true, answer: "no"))
                case .text(let t, _): reply(AskpassResponse(ok: true, answer: t))
                case .cancel: reply(AskpassResponse(ok: false))
                }
            }
        case .information(let message):
            serviceMessage(message)
            reply(AskpassResponse(ok: true, answer: ""))
        case .hostKeyChanged, .secret:
            askUser(prompt, reply: reply, remember: nil)
        }
    }

    private func askUser(_ prompt: AskpassPrompt, reply: @escaping (AskpassResponse) -> Void, remember: ((String) -> Void)?) {
        guard let handler = promptHandler else { return reply(AskpassResponse(ok: false)) }
        handler.sshSession(self, needs: prompt) { r in
            switch r {
            case let .text(text, shouldRemember):
                if shouldRemember { remember?(text) }
                reply(AskpassResponse(ok: true, answer: text))
            case .accept:
                reply(AskpassResponse(ok: true, answer: "yes"))
            case .reject, .cancel:
                reply(AskpassResponse(ok: false))
            }
        }
    }

    /// Tabby identifies key passphrases by a hash of the key file.
    static func keyID(path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else { return nil }
        #if canImport(CryptoKit)
        return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        // Linux (tests only): a stable non-cryptographic id is enough.
        var h: UInt64 = 1469598103934665603
        for b in data { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
        #endif
    }
}

public extension SSHConfigGenerator {
    static func shellQuote(_ s: String) -> String {
        s.contains(where: { " '\"\\$`!".contains($0) }) ? "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" : s
    }
}

/// Creates `SSHSession`s; jump hosts are resolved through the profile registry.
public final class SSHSessionFactory: SessionFactory {
    public let profileType = "ssh"
    public var environment: SSHSession.Environment
    public weak var promptHandler: SSHPromptHandler?
    private let resolveProfile: (String) -> Profile?

    public init(environment: SSHSession.Environment, resolveProfile: @escaping (String) -> Profile?) {
        self.environment = environment
        self.resolveProfile = resolveProfile
    }

    public func makeSession(profile: Profile, context: SessionContext) throws -> TerminalSession {
        let s = SSHSession(profile: profile, context: context, environment: environment) { [resolveProfile] id in
            resolveProfile(id).map { SSHOptions($0.options) }
        }
        s.promptHandler = promptHandler
        return s
    }
}
