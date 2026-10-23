#if os(macOS)
import Foundation
import TabbyCore
import TabbySSH

/// The profile editor's "Test connection": connect, check the host key and log in with the
/// editor's values, open no shell, and say how it went.
public enum SSHConnectionTest {
    public enum Outcome: Equatable, Sendable {
        case success(String)
        case failure(String)
    }

    /// A profile as the editor has it, through the connector (jump hosts, proxies) on a
    /// connection of its own that is closed afterwards.
    @MainActor
    public static func run(profile: Profile, connector: SSHConnector, prompter: SSHConnectionPrompter) async -> Outcome {
        var own = profile
        var options = own.options
        options["reuseSession"] = .bool(false)
        own.options = options
        do {
            let connection = try await connector.acquire(profile: own, prompter: prompter)
            let outcome = Outcome.success(L("Connected as {resolvedUser} · {hostKeyType} {hostKeyFingerprint}", ["resolvedUser": connection.resolvedUser, "hostKeyType": connection.hostKeyType, "hostKeyFingerprint": connection.hostKeyFingerprint]))
            connector.release(connection)
            return outcome
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public static func run(options: SSHConnectionOptions, prompter: SSHConnectionPrompter, passwords: PasswordStore) async -> Outcome {
        let connection = SSHConnection(options: options, prompter: prompter, passwords: passwords)
        do {
            try await connection.connect()
            connection.disconnect()
            return .success(L("Connected as {resolvedUser} · {hostKeyType} {hostKeyFingerprint}", ["resolvedUser": connection.resolvedUser, "hostKeyType": connection.hostKeyType, "hostKeyFingerprint": connection.hostKeyFingerprint]))
        } catch {
            return .failure((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
#endif
