#if os(macOS)
import CLibSSH
import Foundation
import TabbyCore
import TabbySSH

// MARK: Public types

/// What a connection needs; the session layer fills it from a profile and the settings.
public struct SSHConnectionOptions: Sendable {
    public var host: String
    public var port: Int
    /// Empty asks for one; `$NAME` takes it from the environment (Tabby).
    public var user: String
    public var auth: SSHAuthMethod?
    public var privateKeys: [String] = []
    public var profilePassword: String?
    /// The app's known_hosts (new keys are written here) and a read-only one (`~/.ssh/known_hosts`).
    public var knownHostsFile: String
    public var globalKnownHostsFile: String?
    public var verifyHostKeys = true
    /// The agent's socket; nil means no agent.
    public var agentSocket: String?
    /// Home folder for `~/` in key paths and ssh's default identities (injected by tests).
    public var homeDirectory: String = NSHomeDirectory()
    public var syncedKeys: SyncedKeys = .none
    public var connectTimeout: TimeInterval?
    /// Seconds between keep-alive requests; 0 sends none.
    public var keepaliveInterval: TimeInterval = 0
    /// Tabby's lists by kind: `kex`, `cipher`, `hmac`, `serverHostKey`, `compression`.
    public var algorithms: [String: [String]] = [:]
    public var proxyCommand: String?
    public var skipBanner = false
    /// A transport that is already connected (jump host channel, SOCKS or HTTP proxy).
    public var socket: Int32?

    public init(host: String, port: Int = 22, user: String, knownHostsFile: String = ConfigPaths.standard().knownHostsFile.path) {
        self.host = host
        self.port = port
        self.user = user
        self.knownHostsFile = knownHostsFile
    }
}

public struct HostKeyRequest: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var keyType: String
    /// `SHA256:…`, as ssh-keygen prints it.
    public var fingerprint: String
    /// Set when known_hosts has another key for this host.
    public var previousFingerprint: String?
}

public enum HostKeyDecision: Sendable, Equatable {
    case reject, acceptOnce, acceptAndRemember
}

public struct SecretAnswer: Sendable {
    public var value: String
    public var remember: Bool
    public init(value: String, remember: Bool) {
        self.value = value
        self.remember = remember
    }
}

/// One keyboard-interactive round (`sshAuth` panel).
public struct KeyboardInteractiveRound: Sendable {
    public struct Prompt: Equatable, Sendable {
        public var text: String
        public var echo: Bool
        /// Tabby: a hidden prompt that mentions "password".
        public var isPasswordLike: Bool { !echo && text.lowercased().contains("password") }
    }

    public var host: String
    public var name: String
    public var instruction: String
    public var prompts: [Prompt]
    /// Answers filled in beforehand (the saved password for password-like prompts).
    public var prefilled: [String?]
}

public struct KeyboardInteractiveAnswer: Sendable, Equatable {
    public var answers: [String]
    /// Save the answers to password-like prompts once the login works.
    public var remember: Bool
    public init(answers: [String], remember: Bool) {
        self.answers = answers
        self.remember = remember
    }
}

/// The questions a connection asks; answered on the main actor (sheets and panels).
public protocol SSHConnectionPrompter: AnyObject, Sendable {
    @MainActor func verifyHostKey(_ request: HostKeyRequest) async -> HostKeyDecision
    @MainActor func password(user: String, host: String) async -> SecretAnswer?
    @MainActor func passphrase(keyPath: String) async -> SecretAnswer?
    /// nil cancels the login.
    @MainActor func keyboardInteractive(_ round: KeyboardInteractiveRound) async -> KeyboardInteractiveAnswer?
    @MainActor func username(host: String) async -> String?
    /// A service line for the terminal ("Using saved password", …).
    @MainActor func message(_ text: String)
}

public enum SSHConnectionError: Error, Equatable, LocalizedError {
    case connectFailed(String)
    case hostKeyRejected
    case authenticationRejected
    case cancelled
    case noUsername
    case channelFailed(String)
    case disconnected

    public var errorDescription: String? {
        switch self {
        case .connectFailed(let message): return message
        case .hostKeyRejected: return "Host key verification failed"
        case .authenticationRejected: return "Authentication rejected"
        case .cancelled: return "Cancelled"
        case .noUsername: return "No username"
        case .channelFailed(let message): return message
        case .disconnected: return "Disconnected"
        }
    }
}

/// Where a channel's output goes. Called on the connection's thread.
public struct SSHChannelHandlers: Sendable {
    public var data: @Sendable (Data) -> Void
    /// The channel closed; the remote command's exit status when it sent one.
    public var closed: @Sendable (Int32?) -> Void
    /// The remote side will send nothing more.
    public var eof: (@Sendable () -> Void)?

    public init(data: @escaping @Sendable (Data) -> Void, closed: @escaping @Sendable (Int32?) -> Void,
                eof: (@Sendable () -> Void)? = nil) {
        self.data = data
        self.closed = closed
        self.eof = eof
    }
}

// MARK: Connection

/// One SSH connection over libssh. Every libssh call runs on the connection's own thread:
/// connecting and authenticating first (prompts wait for the main actor), then an
/// `ssh_event` loop that serves the channels. Other threads hand it work through `enqueue`,
/// which wakes the loop through a pipe.
public final class SSHConnection: @unchecked Sendable {
    public let options: SSHConnectionOptions
    let prompter: SSHConnectionPrompter
    let passwords: PasswordStore

    private var session: ssh_session?
    private var event: ssh_event?
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private let lock = NSLock()
    private var tasks: [() -> Void] = []
    private var isRunning = false
    private var stopRequested = false
    private var channels: [ChannelBox] = []
    /// Called on the connection's thread when the loop ends (remote close, error, disconnect).
    public var onDisconnect: (@Sendable (SSHConnectionError?) -> Void)?
    /// The user name the login used (after `$NAME` and the prompt).
    public private(set) var resolvedUser = ""

    public init(options: SSHConnectionOptions, prompter: SSHConnectionPrompter, passwords: PasswordStore) {
        self.options = options
        self.prompter = prompter
        self.passwords = passwords
    }

    /// Connects, checks the host key and logs in; afterwards the connection serves channels
    /// until `disconnect()` or the server goes away.
    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let thread = Thread { [self] in
                do {
                    try establish()
                } catch {
                    teardown()
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
                runLoop()
            }
            thread.name = "SSH \(options.host):\(options.port)"
            thread.start()
        }
    }

    public func disconnect() {
        _ = enqueue { [self] in stopRequested = true }
    }

    public var isConnected: Bool { lock.withLock { isRunning } }

    // MARK: Main-actor bridge

    /// Runs `body` on the main actor and waits for it (the connection thread may block).
    func ask<T>(_ body: @escaping @MainActor () async -> T) -> T {
        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            box.value = await body()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    func say(_ text: String) {
        let prompter = prompter
        Task { @MainActor in prompter.message(text) }
    }

    func lastError() -> String {
        guard let session else { return "unknown error" }
        return String(cString: ssh_get_error(UnsafeMutableRawPointer(session)))
    }

    // MARK: Connecting

    private func establish() throws {
        _ = LibSSH.initialised
        guard let s = ssh_new() else { throw SSHConnectionError.connectFailed("libssh could not start a session") }
        session = s

        var user = options.user
        if user.hasPrefix("$") { user = ProcessInfo.processInfo.environment[String(user.dropFirst())] ?? "" }
        if user.isEmpty {
            let host = options.host
            let prompter = prompter
            guard let answer = ask({ await prompter.username(host: host) }), !answer.isEmpty else { throw SSHConnectionError.noUsername }
            user = answer
        }
        resolvedUser = user

        ssh_options_set(s, SSH_OPTIONS_HOST, options.host)
        var port = UInt32(options.port)
        ssh_options_set(s, SSH_OPTIONS_PORT, &port)
        ssh_options_set(s, SSH_OPTIONS_USER, user)
        var processConfig = false
        ssh_options_set(s, SSH_OPTIONS_PROCESS_CONFIG, &processConfig)
        ssh_options_set(s, SSH_OPTIONS_SSH_DIR, (options.homeDirectory as NSString).appendingPathComponent(".ssh"))
        try? FileManager.default.createDirectory(atPath: (options.knownHostsFile as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        ssh_options_set(s, SSH_OPTIONS_KNOWNHOSTS, options.knownHostsFile)
        ssh_options_set(s, SSH_OPTIONS_GLOBAL_KNOWNHOSTS, options.globalKnownHostsFile ?? "/dev/null")
        if let timeout = options.connectTimeout, timeout > 0 {
            var seconds = Int(timeout.rounded(.up))
            ssh_options_set(s, SSH_OPTIONS_TIMEOUT, &seconds)
        }
        if let agent = options.agentSocket { ssh_options_set(s, SSH_OPTIONS_IDENTITY_AGENT, agent) }
        if let command = options.proxyCommand, !command.isEmpty { ssh_options_set(s, SSH_OPTIONS_PROXYCOMMAND, command) }
        if var fd = options.socket { ssh_options_set(s, SSH_OPTIONS_FD, &fd) }
        for (kind, list) in options.algorithms where !list.isEmpty {
            let joined = list.joined(separator: ",")
            switch kind {
            case "kex": ssh_options_set(s, SSH_OPTIONS_KEY_EXCHANGE, joined)
            case "cipher":
                ssh_options_set(s, SSH_OPTIONS_CIPHERS_C_S, joined)
                ssh_options_set(s, SSH_OPTIONS_CIPHERS_S_C, joined)
            case "hmac":
                ssh_options_set(s, SSH_OPTIONS_HMAC_C_S, joined)
                ssh_options_set(s, SSH_OPTIONS_HMAC_S_C, joined)
            case "serverHostKey": ssh_options_set(s, SSH_OPTIONS_HOSTKEYS, joined)
            case "compression":
                ssh_options_set(s, SSH_OPTIONS_COMPRESSION_C_S, joined)
                ssh_options_set(s, SSH_OPTIONS_COMPRESSION_S_C, joined)
            default: break
            }
        }
        ssh_set_blocking(s, 1)

        guard ssh_connect(s) == SSH_OK else { throw SSHConnectionError.connectFailed(lastError()) }
        try verifyHostKey(s)
        try authenticate(s, user: user)
        if !options.skipBanner, let banner = ssh_get_issue_banner(s) {
            let text = String(cString: banner).trimmingCharacters(in: .whitespacesAndNewlines)
            ssh_string_free_char(banner)
            if !text.isEmpty { say(text) }
        }

        guard let e = ssh_event_new() else { throw SSHConnectionError.connectFailed("libssh could not poll") }
        event = e
        ssh_event_add_session(e, s)
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw SSHConnectionError.connectFailed("no pipe") }
        wakeRead = fds[0]
        wakeWrite = fds[1]
        _ = fcntl(wakeRead, F_SETFL, O_NONBLOCK)
        _ = fcntl(wakeWrite, F_SETFL, O_NONBLOCK)
        ssh_event_add_fd(e, wakeRead, Int16(POLLIN), wakeCallback, Unmanaged.passUnretained(self).toOpaque())
        lock.withLock { isRunning = true }
    }

    // MARK: Host key

    static func fingerprint(_ key: ssh_key) -> String {
        var hash: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard ssh_get_publickey_hash(key, SSH_PUBLICKEY_HASH_SHA256, &hash, &length) == 0, let hash else { return "" }
        defer { var h: UnsafeMutablePointer<UInt8>? = hash; ssh_clean_pubkey_hash(&h) }
        guard let text = ssh_get_fingerprint_hash(SSH_PUBLICKEY_HASH_SHA256, hash, length) else { return "" }
        defer { ssh_string_free_char(text) }
        return String(cString: text)
    }

    private func verifyHostKey(_ s: ssh_session) throws {
        var serverKey: ssh_key?
        guard ssh_get_server_publickey(s, &serverKey) == SSH_OK, let key = serverKey else {
            throw SSHConnectionError.connectFailed(lastError())
        }
        defer { ssh_key_free(key) }
        let fingerprint = Self.fingerprint(key)
        let type = String(cString: ssh_key_type_to_char(ssh_key_type(key)))
        say("Host key fingerprint: \(type) \(fingerprint)")

        let state = ssh_session_is_known_server(s)
        var previous: String?
        switch state {
        case SSH_KNOWN_HOSTS_OK:
            return
        case SSH_KNOWN_HOSTS_CHANGED, SSH_KNOWN_HOSTS_OTHER:
            // libssh does not hand back the entry that disagrees; read the files.
            let files = [options.knownHostsFile] + (options.globalKnownHostsFile.map { [$0] } ?? [])
            previous = KnownHostsLookup.fingerprints(host: options.host, port: options.port, files: files)
                .sorted { a, _ in a.type == type }.first?.fingerprint ?? "unknown"
        case SSH_KNOWN_HOSTS_NOT_FOUND, SSH_KNOWN_HOSTS_UNKNOWN:
            break
        default:
            throw SSHConnectionError.connectFailed(lastError())
        }
        guard options.verifyHostKeys else { return }
        let request = HostKeyRequest(host: options.host, port: options.port, keyType: type, fingerprint: fingerprint,
                                     previousFingerprint: previous)
        let prompter = prompter
        switch ask({ await prompter.verifyHostKey(request) }) {
        case .reject:
            throw SSHConnectionError.hostKeyRejected
        case .acceptOnce:
            return
        case .acceptAndRemember:
            if ssh_session_update_known_hosts(s) != SSH_OK { say("Could not save the host key: \(lastError())") }
        }
    }

    // MARK: Authentication

    private var afterLogin: [() -> Void] = []

    private func allowedMethods(_ s: ssh_session) -> [String] {
        let mask = UInt32(bitPattern: ssh_userauth_list(s, nil))
        var names: [String] = []
        if mask & UInt32(SSH_AUTH_METHOD_PUBLICKEY) != 0 { names.append("publickey") }
        if mask & UInt32(SSH_AUTH_METHOD_PASSWORD) != 0 { names.append("password") }
        if mask & UInt32(SSH_AUTH_METHOD_INTERACTIVE) != 0 { names.append("keyboard-interactive") }
        return names
    }

    func expand(_ path: String) -> String {
        if path.hasPrefix("~/") { return options.homeDirectory + String(path.dropFirst()) }
        if path.hasPrefix("file://"), let url = URL(string: path) { return url.path }
        return path
    }

    private func authenticate(_ s: ssh_session, user: String) throws {
        let none = ssh_userauth_none(s, nil)
        if none == SSH_AUTH_SUCCESS.rawValue { return }
        if none == SSH_AUTH_ERROR.rawValue { throw SSHConnectionError.connectFailed(lastError()) }

        let host = options.host
        let port = options.port
        let stored = onMain { passwords.password(host: host, port: port, user: user) }
        let home = options.homeDirectory
        let defaults = options.syncedKeys.identitiesForProfileWithoutKeys(fileExists: { FileManager.default.fileExists(atPath: $0) })
        let defaultIdentities = defaults.isEmpty
            ? SyncedKeys.defaultIdentityNames.map { home + "/.ssh/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
            : defaults
        let agentAvailable = options.agentSocket.map(Self.isSocket) ?? false
        var steps = SSHAuthPlan.steps(auth: options.auth, host: host, user: user,
                                      privateKeys: options.privateKeys.map { options.syncedKeys.resolve($0) }.map(expand),
                                      defaultIdentities: defaultIdentities, agentAvailable: agentAvailable,
                                      fileExists: { FileManager.default.fileExists(atPath: $0) },
                                      profilePassword: options.profilePassword, storedPassword: stored)
        steps.removeAll { $0 == .none }
        var plan = SSHAuthPlan(steps: steps, allowed: allowedMethods(s))
        var triedAgent = false

        while let step = plan.next() {
            let result: Int32
            switch step {
            case .none:
                continue
            case .agent:
                // libssh tries every agent identity in one go.
                if triedAgent { continue }
                triedAgent = true
                result = ssh_userauth_agent(s, nil)
                if result != SSH_AUTH_SUCCESS.rawValue { say("Failed to authenticate using agent") }
            case .publicKey(let file):
                guard let r = try tryKey(s, path: file) else { continue }
                result = r
            case .savedPassword(let password):
                say("Using saved password")
                result = ssh_userauth_password(s, nil, password)
                if result == SSH_AUTH_DENIED.rawValue, password == stored {
                    onMain { passwords.deletePassword(host: host, port: port, user: user) }
                }
            case .keyboardInteractive(let saved):
                result = try keyboardInteractive(s, savedPassword: saved, user: user)
            case .promptPassword:
                let prompter = prompter
                guard let answer = ask({ await prompter.password(user: user, host: host) }) else { throw SSHConnectionError.cancelled }
                result = ssh_userauth_password(s, nil, answer.value)
                if answer.remember, result == SSH_AUTH_SUCCESS.rawValue {
                    afterLogin.append { [passwords] in passwords.savePassword(answer.value, host: host, port: port, user: user) }
                }
            }
            switch result {
            case SSH_AUTH_SUCCESS.rawValue:
                let saves = afterLogin
                afterLogin = []
                onMain { saves.forEach { $0() } }
                return
            case SSH_AUTH_PARTIAL.rawValue:
                plan.failed(partialSuccess: true, allowedMethods: allowedMethods(s))
            case SSH_AUTH_DENIED.rawValue:
                plan.failed(partialSuccess: false, allowedMethods: allowedMethods(s))
            default:
                throw SSHConnectionError.connectFailed(lastError())
            }
        }
        throw SSHConnectionError.authenticationRejected
    }

    static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    /// Public key authentication with one key file; nil when the file can't be used.
    private func tryKey(_ s: ssh_session, path: String) throws -> Int32? {
        let name = (path as NSString).lastPathComponent
        guard FileManager.default.fileExists(atPath: path) else {
            say("Could not load private key \(path): no such file")
            return nil
        }
        // libssh's public-key import also reads a private key's public half, so look at the
        // header first.
        let head = (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)).read(upToCount: 64)) ?? nil
        let header = head.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let isPrivate = header.contains("PRIVATE KEY") || header.hasPrefix("PuTTY-User-Key-File")
        var publicKey: ssh_key?
        if !isPrivate, ssh_pki_import_pubkey_file(path, &publicKey) == SSH_OK {
            ssh_key_free(publicKey)
            say("Expected a private key, but \(path) appears to be a public key. Skipping it for private key authentication.")
            return nil
        }
        say("Trying private key: \(name)")
        var key: ssh_key?
        if ssh_pki_import_privkey_file(path, nil, nil, nil, &key) != SSH_OK {
            key = nil
            let id = SSHSession.keyID(path: path)
            if let id, let saved = onMain({ passwords.passphrase(keyID: id) }) {
                if ssh_pki_import_privkey_file(path, saved, nil, nil, &key) != SSH_OK {
                    key = nil
                    onMain { passwords.deletePassphrase(keyID: id) }
                }
            }
            var attempts = 0
            while key == nil, attempts < 3 {
                attempts += 1
                let prompter = prompter
                guard let answer = ask({ await prompter.passphrase(keyPath: path) }) else { throw SSHConnectionError.cancelled }
                if ssh_pki_import_privkey_file(path, answer.value, nil, nil, &key) == SSH_OK, answer.remember, let id {
                    afterLogin.append { [passwords] in passwords.savePassphrase(answer.value, keyID: id) }
                } else if key == nil {
                    say("Failed to load private key \(name): wrong passphrase")
                }
            }
            guard key != nil else { return nil }
        }
        defer { ssh_key_free(key) }
        return ssh_userauth_publickey(s, nil, key)
    }

    private func keyboardInteractive(_ s: ssh_session, savedPassword: String?, user: String) throws -> Int32 {
        var result = ssh_userauth_kbdint(s, nil, nil)
        var remembered: String?
        while result == SSH_AUTH_INFO.rawValue {
            let name = ssh_userauth_kbdint_getname(s).map { String(cString: $0) } ?? ""
            let instruction = ssh_userauth_kbdint_getinstruction(s).map { String(cString: $0) } ?? ""
            let count = ssh_userauth_kbdint_getnprompts(s)
            var prompts: [KeyboardInteractiveRound.Prompt] = []
            for index in 0..<max(0, count) {
                var echo: CChar = 0
                let text = ssh_userauth_kbdint_getprompt(s, UInt32(index), &echo).map { String(cString: $0) } ?? ""
                prompts.append(.init(text: text, echo: echo != 0))
            }
            if !prompts.isEmpty {
                say("Keyboard-interactive auth requested: \(name)")
                let round = KeyboardInteractiveRound(host: options.host, name: name, instruction: instruction, prompts: prompts,
                                                     prefilled: prompts.map { $0.isPasswordLike ? savedPassword : nil })
                let prompter = prompter
                guard let answer = ask({ await prompter.keyboardInteractive(round) }) else { throw SSHConnectionError.cancelled }
                for (index, value) in answer.answers.enumerated() where index < prompts.count {
                    ssh_userauth_kbdint_setanswer(s, UInt32(index), value)
                    if answer.remember, prompts[index].isPasswordLike { remembered = value }
                }
            }
            result = ssh_userauth_kbdint(s, nil, nil)
        }
        if result == SSH_AUTH_SUCCESS.rawValue, let remembered {
            let host = options.host
            let port = options.port
            afterLogin.append { [passwords] in passwords.savePassword(remembered, host: host, port: port, user: user) }
        }
        return result
    }

    // MARK: Loop

    /// Hands work to the connection's thread; false when the connection is closed.
    @discardableResult
    func enqueue(_ work: @escaping () -> Void) -> Bool {
        let accepted = lock.withLock { () -> Bool in
            guard isRunning else { return false }
            tasks.append(work)
            return true
        }
        if accepted {
            var byte: UInt8 = 1
            _ = write(wakeWrite, &byte, 1)
        }
        return accepted
    }

    /// Runs `work` on the connection's thread and returns its result.
    func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let accepted = enqueue {
                do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
            }
            if !accepted { continuation.resume(throwing: SSHConnectionError.disconnected) }
        }
    }

    fileprivate func drainWakePipe() {
        var buffer = [UInt8](repeating: 0, count: 64)
        while read(wakeRead, &buffer, buffer.count) > 0 {}
    }

    private func runLoop() {
        var lastKeepalive = Date()
        var lost: SSHConnectionError?
        while true {
            let rc = ssh_event_dopoll(event, 250)
            let work = lock.withLock { () -> [() -> Void] in
                defer { tasks.removeAll() }
                return tasks
            }
            work.forEach { $0() }
            reapChannels()
            if stopRequested { break }
            if rc == SSH_ERROR || ssh_is_connected(session) == 0 {
                lost = .disconnected
                break
            }
            if options.keepaliveInterval > 0, Date().timeIntervalSince(lastKeepalive) >= options.keepaliveInterval {
                lastKeepalive = Date()
                if ssh_send_keepalive(session) != SSH_OK {
                    lost = .disconnected
                    break
                }
            }
        }
        // Work that arrived meanwhile is refused from here on.
        let leftovers = lock.withLock { () -> [() -> Void] in
            isRunning = false
            defer { tasks.removeAll() }
            return tasks
        }
        leftovers.forEach { $0() }
        teardown()
        onDisconnect?(lost)
    }

    // MARK: Channels

    func register(_ box: ChannelBox) {
        channels.append(box)
    }

    private func reapChannels() {
        for bridge in bridges {
            bridge.pullBuffered()
            let wanted = bridge.wantedEvents
            guard wanted != bridge.registeredEvents, let event else { continue }
            // Never changed inside a poll callback; only here, between polls.
            if bridge.registeredEvents != 0 { ssh_event_remove_fd(event, bridge.fd) }
            if wanted != 0 {
                ssh_event_add_fd(event, bridge.fd, wanted, bridgeEvent, Unmanaged.passUnretained(bridge).toOpaque())
            }
            bridge.registeredEvents = wanted
        }
        bridges.removeAll { bridge in
            guard bridge.isFinished, bridge.registeredEvents == 0 else { return false }
            close(bridge.fd)
            bridge.box.isBridged = false
            bridge.box.sink = nil
            bridge.box.canWrite = nil
            bridge.box.remoteEOF = nil
            return true
        }
        channels.removeAll { box in
            guard box.isClosed, !box.isBridged else { return false }
            box.free()
            return true
        }
    }

    // MARK: Bridges

    private var bridges: [Bridge] = []

    /// Joins `fd` and `channel` until either side ends; the connection owns and closes `fd`.
    func bridge(_ box: ChannelBox, fd: Int32) {
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let bridge = Bridge(fd: fd, box: box)
        bridges.append(bridge)
        register(box)
        reapChannels()
    }

    /// Opens a direct-tcpip channel to `host:port` (seen from the server) and returns a local
    /// socket joined to it: jump hosts hand it to the next connection as its transport.
    public func openBridgedSocket(to host: String, port: Int) async throws -> Int32 {
        try await perform { [self] in
            var fds: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SSHConnectionError.channelFailed("no socket pair") }
            let (mine, theirs) = (fds[0], fds[1])
            do {
                let box = try openDirectTCPIP(host: host, port: port, deliverTo: mine)
                bridge(box, fd: mine)
                var yes: Int32 = 1
                setsockopt(theirs, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                return theirs
            } catch {
                close(mine)
                close(theirs)
                throw error
            }
        }
    }

    /// A direct-tcpip channel whose output is written to `fd` (on the connection's thread).
    func openDirectTCPIP(host: String, port: Int, deliverTo fd: Int32) throws -> ChannelBox {
        guard let session, let channel = ssh_channel_new(session) else { throw SSHConnectionError.channelFailed(lastError()) }
        // The bridge installs its sink and EOF handling once the channel is open.
        let box = ChannelBox(channel: channel, handlers: SSHChannelHandlers(data: { _ in }, closed: { _ in }))
        guard ssh_channel_open_forward(channel, host, Int32(port), "127.0.0.1", 0) == SSH_OK else {
            let message = lastError()
            box.free()
            throw SSHConnectionError.channelFailed("Could not open a channel to \(host):\(port): \(message)")
        }
        return box
    }

    private func teardown() {
        for bridge in bridges {
            if bridge.registeredEvents != 0, let event { ssh_event_remove_fd(event, bridge.fd) }
            close(bridge.fd)
        }
        bridges.removeAll()
        for box in channels {
            box.finish(status: nil)
            box.free()
        }
        channels.removeAll()
        if let event {
            if wakeRead >= 0 { ssh_event_remove_fd(event, wakeRead) }
            if let session { ssh_event_remove_session(event, session) }
            ssh_event_free(event)
            self.event = nil
        }
        if wakeRead >= 0 { close(wakeRead); wakeRead = -1 }
        if wakeWrite >= 0 { close(wakeWrite); wakeWrite = -1 }
        if let session {
            ssh_disconnect(session)
            ssh_free(session)
            self.session = nil
        }
    }

    /// Opens an interactive shell with a PTY (and agent forwarding when asked).
    public func openShell(term: String, columns: Int, rows: Int, handlers: SSHChannelHandlers,
                          forwardAgent: Bool = false) async throws -> SSHShellChannel {
        try await perform { [self] in
            guard let session, let channel = ssh_channel_new(session) else { throw SSHConnectionError.channelFailed(lastError()) }
            let box = ChannelBox(channel: channel, handlers: handlers)
            guard ssh_channel_open_session(channel) == SSH_OK else {
                box.free()
                throw SSHConnectionError.channelFailed("Remote rejected opening a shell channel: \(lastError())")
            }
            if ssh_channel_request_pty_size(channel, term.isEmpty ? "xterm-256color" : term, Int32(columns), Int32(rows)) != SSH_OK {
                box.free()
                throw SSHConnectionError.channelFailed("Remote rejected the terminal: \(lastError())")
            }
            if forwardAgent, ssh_channel_request_auth_agent(channel) != SSH_OK {
                say("Agent forwarding was refused")
            }
            guard ssh_channel_request_shell(channel) == SSH_OK else {
                box.free()
                throw SSHConnectionError.channelFailed("Remote rejected opening a shell channel: \(lastError())")
            }
            register(box)
            return SSHShellChannel(connection: self, box: box)
        }
    }
}

/// A shell channel: write, resize, close. Output arrives through its handlers.
public final class SSHShellChannel: @unchecked Sendable {
    let connection: SSHConnection
    let box: ChannelBox

    init(connection: SSHConnection, box: ChannelBox) {
        self.connection = connection
        self.box = box
    }

    public func write(_ data: Data) {
        connection.enqueue { [box] in box.write(data) }
    }

    public func resize(columns: Int, rows: Int) {
        connection.enqueue { [box] in
            guard !box.isClosed else { return }
            ssh_channel_change_pty_size(box.channel, Int32(columns), Int32(rows))
        }
    }

    public func close() {
        connection.enqueue { [box] in box.close() }
    }
}

// MARK: Channel plumbing

/// A channel with its callback table (libssh keeps a pointer to it) and handlers.
final class ChannelBox {
    let channel: ssh_channel
    let handlers: SSHChannelHandlers
    /// Takes the data instead of `handlers.data` and says how much it took; the rest stays in
    /// libssh's buffer and the server's window stops growing (flow control for bridges).
    var sink: ((UnsafeRawBufferPointer) -> Int)?
    /// The remote window opened again after `write` would have blocked.
    var canWrite: (() -> Void)?
    /// The remote side sent EOF (for bridges, besides `handlers.eof`).
    var remoteEOF: (() -> Void)?
    /// A bridge still uses the channel; it is freed only after the bridge is gone.
    var isBridged = false
    private let callbacks: UnsafeMutablePointer<ssh_channel_callbacks_struct>
    private(set) var isClosed = false
    private var finished = false
    private var freed = false
    var exitStatus: Int32?

    init(channel: ssh_channel, handlers: SSHChannelHandlers) {
        self.channel = channel
        self.handlers = handlers
        callbacks = .allocate(capacity: 1)
        callbacks.initialize(to: ssh_channel_callbacks_struct())
        callbacks.pointee.size = MemoryLayout<ssh_channel_callbacks_struct>.size
        callbacks.pointee.userdata = Unmanaged.passUnretained(self).toOpaque()
        callbacks.pointee.channel_data_function = channelData
        callbacks.pointee.channel_close_function = channelClose
        callbacks.pointee.channel_eof_function = channelEOF
        callbacks.pointee.channel_write_wontblock_function = channelWontBlock
        callbacks.pointee.channel_exit_status_function = channelExitStatus
        ssh_set_channel_callbacks(channel, callbacks)
    }

    func write(_ data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = ssh_channel_write(channel, raw.baseAddress! + offset, UInt32(raw.count - offset))
                if written <= 0 { break }
                offset += Int(written)
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        ssh_channel_send_eof(channel)
        ssh_channel_close(channel)
        isClosed = true
        finish(status: exitStatus)
    }

    func markClosed() {
        isClosed = true
        finish(status: exitStatus)
    }

    func finish(status: Int32?) {
        guard !finished else { return }
        finished = true
        handlers.closed(status)
    }

    func free() {
        guard !freed else { return }
        freed = true
        ssh_remove_channel_callbacks(channel, callbacks)
        if ssh_channel_is_closed(channel) == 0 { ssh_channel_close(channel) }
        ssh_channel_free(channel)
        callbacks.deinitialize(count: 1)
        callbacks.deallocate()
    }
}

private func box(_ userdata: UnsafeMutableRawPointer?) -> ChannelBox {
    Unmanaged<ChannelBox>.fromOpaque(userdata!).takeUnretainedValue()
}

private let channelData: ssh_channel_data_callback = { _, _, data, length, _, userdata in
    guard let data, length > 0 else { return 0 }
    let channel = box(userdata)
    if let sink = channel.sink {
        return Int32(sink(UnsafeRawBufferPointer(start: data, count: Int(length))))
    }
    channel.handlers.data(Data(bytes: data, count: Int(length)))
    return Int32(length)
}

private let channelWontBlock: ssh_channel_write_wontblock_callback = { _, _, _, userdata in
    box(userdata).canWrite?()
    return 0
}

private let channelClose: ssh_channel_close_callback = { _, _, userdata in
    box(userdata).markClosed()
}

private let channelEOF: ssh_channel_eof_callback = { _, _, userdata in
    let channel = box(userdata)
    channel.handlers.eof?()
    channel.remoteEOF?()
}

private let channelExitStatus: ssh_channel_exit_status_callback = { _, _, status, userdata in
    box(userdata).exitStatus = status
}

/// A local socket joined to a channel, with flow control both ways: data for the socket
/// waits in `pending` (up to `limit`, beyond which libssh keeps it and the server's window
/// stops growing), and the socket is not read while the channel's window is closed.
final class Bridge {
    static let limit = 1 << 20
    let fd: Int32
    let box: ChannelBox
    var registeredEvents: Int16 = 0
    private var pending = Data()
    private var localEOF = false
    private var remoteEOF = false
    private var windowOpen = true

    init(fd: Int32, box: ChannelBox) {
        self.fd = fd
        self.box = box
        box.isBridged = true
        box.sink = { [unowned self] bytes in take(bytes) }
        box.canWrite = { [unowned self] in windowOpen = true }
        box.remoteEOF = { [unowned self] in remoteFinished() }
    }

    var isFinished: Bool { box.isClosed && pending.isEmpty || (box.isClosed && localEOF) }

    var wantedEvents: Int16 {
        if box.isClosed && pending.isEmpty { return 0 }
        var events: Int16 = 0
        if !localEOF && !box.isClosed && windowOpen { events |= Int16(POLLIN) }
        if !pending.isEmpty { events |= Int16(POLLOUT) }
        return events
    }

    /// Channel → socket: write what fits now, keep the rest, refuse beyond the limit.
    func take(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard pending.count < Self.limit else { return 0 }
        let room = min(bytes.count, Self.limit - pending.count)
        var offset = 0
        if pending.isEmpty {
            while offset < room {
                let n = write(fd, bytes.baseAddress! + offset, room - offset)
                if n > 0 { offset += n } else { break }
            }
        }
        if offset < room { pending.append(contentsOf: UnsafeRawBufferPointer(rebasing: bytes[offset..<room])) }
        return room
    }

    /// Data libssh kept while `pending` was full.
    func pullBuffered() {
        guard !box.isClosed else { return }
        if !windowOpen, ssh_channel_window_size(box.channel) > 0 { windowOpen = true }
        guard !box.isClosed, pending.count < Self.limit / 2, ssh_channel_poll(box.channel, 0) > 0 else {
            if !remoteEOF, !box.isClosed, ssh_channel_is_eof(box.channel) != 0, pending.isEmpty {
                remoteEOF = true
                shutdown(fd, SHUT_WR)
            }
            return
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let n = ssh_channel_read_nonblocking(box.channel, &buffer, UInt32(min(buffer.count, Self.limit - pending.count)), 0)
        if n > 0 { _ = buffer.withUnsafeBytes { take(UnsafeRawBufferPointer(rebasing: $0[0..<Int(n)])) } }
    }

    func handle(_ revents: Int32) {
        if revents & Int32(POLLOUT) != 0, !pending.isEmpty {
            let written = pending.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            if written > 0 { pending.removeFirst(written) }
            if pending.isEmpty, remoteEOF { shutdown(fd, SHUT_WR) }
        }
        if revents & Int32(POLLIN | POLLHUP | POLLERR) != 0 { readable() }
    }

    /// Socket → channel, no more than the channel's window takes without blocking.
    private func readable() {
        guard !localEOF, !box.isClosed else { return }
        let window = Int(ssh_channel_window_size(box.channel))
        guard window > 0 else {
            windowOpen = false
            return
        }
        var buffer = [UInt8](repeating: 0, count: min(32_768, window))
        let n = read(fd, &buffer, buffer.count)
        if n > 0 {
            box.write(Data(buffer[0..<n]))
        } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
            // The local side is done sending.
            localEOF = true
            ssh_channel_send_eof(box.channel)
            if n < 0 { box.close() }
        }
    }

    /// The channel said EOF: once `pending` is written, the socket's write side shuts.
    func remoteFinished() {
        remoteEOF = true
        if pending.isEmpty { shutdown(fd, SHUT_WR) }
    }
}

private let bridgeEvent: ssh_event_callback = { _, revents, userdata in
    Unmanaged<Bridge>.fromOpaque(userdata!).takeUnretainedValue().handle(revents)
    return 0
}

private let wakeCallback: ssh_event_callback = { _, _, userdata in
    Unmanaged<SSHConnection>.fromOpaque(userdata!).takeUnretainedValue().drainWakePipe()
    return 0
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
#endif
