#if os(macOS)
import Foundation
import TabbyCore
import TabbySSH

/// Turns profiles into connected `SSHConnection`s. With `reuseSession` (the default) tabs
/// on the same target share one connection, keyed like Tabby's `SSHMultiplexerService`, and
/// it closes with its last user; this replaces OpenSSH's ControlMaster. A jump host is the
/// jump profile's (shared) connection carrying a direct-tcpip channel to the target.
@MainActor
public final class SSHConnector {
    private final class Entry {
        let key: String?
        var task: Task<SSHConnection, Error>?
        var refs = 1
        var jump: SSHConnection?

        init(key: String?) {
            self.key = key
        }
    }

    public var environment: LibSSHSession.Environment
    /// Resolves a `jumpHost` profile id (defaults applied).
    public var resolveProfile: (String) -> Profile? = { _ in nil }
    private var pending: [String: Entry] = [:]
    private var live: [ObjectIdentifier: Entry] = [:]

    /// Connections open now (for tests and diagnostics).
    public var sharedCount: Int { live.count }

    public init(environment: LibSSHSession.Environment) {
        self.environment = environment
    }

    /// A connection for `profile`, shared when it allows; pair every call with `release`.
    public func acquire(profile: Profile, prompter: SSHConnectionPrompter) async throws -> SSHConnection {
        try await acquire(profile, prompter: prompter, chain: [])
    }

    /// Gives a connection back; the last user's release closes it.
    public func release(_ connection: SSHConnection) {
        guard let entry = live[ObjectIdentifier(connection)] else { return connection.disconnect() }
        entry.refs -= 1
        if entry.refs <= 0 { connection.disconnect() }
    }

    // MARK: Internals

    private func acquire(_ profile: Profile, prompter: SSHConnectionPrompter, chain: [String]) async throws -> SSHConnection {
        let options = SSHOptions(profile.options)
        let key = options.reuseSession ? sharingKey(options, depth: 0) : nil
        if let key, let entry = pending[key], let task = entry.task {
            entry.refs += 1
            do {
                return try await task.value
            } catch {
                entry.refs -= 1
                throw error
            }
        }
        let entry = Entry(key: key)
        if let key { pending[key] = entry }
        let task = Task { @MainActor in try await self.open(profile, options, prompter: prompter, chain: chain, entry: entry) }
        entry.task = task
        do {
            return try await task.value
        } catch {
            if let key, pending[key] === entry { pending[key] = nil }
            throw error
        }
    }

    private func open(_ profile: Profile, _ options: SSHOptions, prompter: SSHConnectionPrompter, chain: [String],
                      entry: Entry) async throws -> SSHConnection {
        var connectionOptions = LibSSHSession.connectionOptions(for: options, environment: environment)
        // A proxy command wins over a jump host (Tabby).
        if let jumpID = options.jumpHost, options.proxyCommand == nil {
            let chain = chain + [profile.id]
            guard !chain.contains(jumpID) else {
                throw SSHConnectionError.connectFailed("Jump host loop: \((chain + [jumpID]).joined(separator: " → "))")
            }
            guard let jumpProfile = resolveProfile(jumpID) else {
                throw SSHConnectionError.connectFailed("\(options.host): jump host \"\(jumpID)\" not found in your config")
            }
            let jump = try await acquire(jumpProfile, prompter: prompter, chain: chain)
            do {
                connectionOptions.socket = try await jump.openBridgedSocket(to: options.host, port: options.port)
            } catch {
                release(jump)
                throw error
            }
            entry.jump = jump
        }
        let connection = SSHConnection(options: connectionOptions, prompter: prompter, passwords: environment.passwords)
        connection.onDisconnect = { [weak self, weak connection] _ in
            Task { @MainActor in
                if let connection { self?.ended(connection) }
            }
        }
        do {
            try await connection.connect()
        } catch {
            if let jump = entry.jump {
                entry.jump = nil
                release(jump)
            }
            throw error
        }
        live[ObjectIdentifier(connection)] = entry
        return connection
    }

    private func ended(_ connection: SSHConnection) {
        guard let entry = live.removeValue(forKey: ObjectIdentifier(connection)) else { return }
        if let key = entry.key, pending[key] === entry { pending[key] = nil }
        if let jump = entry.jump {
            entry.jump = nil
            release(jump)
        }
    }

    /// Tabby's key: host, port, user, proxy settings, and the jump host's own key.
    private func sharingKey(_ o: SSHOptions, depth: Int) -> String {
        // Built in steps: as one array literal it was too much for Xcode 16's type checker.
        var parts: [String] = [o.host, String(o.port), o.user]
        parts.append(o.proxyCommand ?? "")
        parts.append(o.socksProxyHost ?? "")
        parts.append(o.socksProxyPort.map { String($0) } ?? "")
        parts.append(o.httpProxyHost ?? "")
        parts.append(o.httpProxyPort.map { String($0) } ?? "")
        var key = parts.joined(separator: ":")
        if let jumpID = o.jumpHost {
            if depth < 8, let jump = resolveProfile(jumpID) {
                key += "$" + sharingKey(SSHOptions(jump.options), depth: depth + 1)
            } else {
                key += "$" + jumpID
            }
        }
        return key
    }
}
#endif
