import Foundation

/// One way of authenticating, in the order the library backend tries them.
public enum SSHAuthStep: Equatable, Sendable {
    case none
    /// Through the agent: one identity (its public half) or, with nil, every agent key.
    case agent(publicKeyFile: String?)
    case publicKey(file: String)
    case savedPassword(String)
    /// Keyboard-interactive; password-like prompts are filled with `savedPassword`.
    case keyboardInteractive(savedPassword: String?)
    case promptPassword

    /// The SSH method name the server lists for it.
    public var method: String {
        switch self {
        case .none: return "none"
        case .agent, .publicKey: return "publickey"
        case .savedPassword, .promptPassword: return "password"
        case .keyboardInteractive: return "keyboard-interactive"
        }
    }
}

/// Tabby's authentication plan (`ssh.ts` and `authMethodSelection.ts`): try each step once,
/// in order, among those the server still allows; a partial success (2FA) adds a fresh
/// keyboard-interactive round.
public struct SSHAuthPlan: Equatable, Sendable {
    public private(set) var remaining: [SSHAuthStep]
    /// What the server allows next (empty: not known yet, try anything).
    public private(set) var allowed: [String]

    public init(steps: [SSHAuthStep], allowed: [String] = []) {
        remaining = steps
        self.allowed = allowed
    }

    /// The steps for a profile. `privateKeys` may use `%h` and `%r`; `defaultIdentities`
    /// stand in when it is empty. `storedPassword` is the Keychain's for the resolved user.
    public static func steps(auth: SSHAuthMethod?, host: String, user: String, privateKeys: [String], defaultIdentities: [String],
                             agentAvailable: Bool, fileExists: (String) -> Bool, profilePassword: String?,
                             storedPassword: String?) -> [SSHAuthStep] {
        let keys = privateKeys.map { $0.replacingOccurrences(of: "%h", with: host).replacingOccurrences(of: "%r", with: user) }
        var list: [SSHAuthStep] = [.none]
        if auth == nil || auth == .agent, agentAvailable {
            for key in keys {
                let pub = key.hasSuffix(".pub") ? key : key + ".pub"
                if fileExists(pub) { list.append(.agent(publicKeyFile: pub)) }
            }
            list.append(.agent(publicKeyFile: nil))
        }
        if auth == nil || auth == .publicKey {
            list += (keys.isEmpty ? defaultIdentities : keys).map { .publicKey(file: $0) }
        }
        if auth == nil || auth == .password, let profilePassword {
            list.append(.savedPassword(profilePassword))
        }
        if auth == nil || auth == .keyboardInteractive {
            if let profilePassword { list.append(.keyboardInteractive(savedPassword: profilePassword)) }
            list.append(.keyboardInteractive(savedPassword: nil))
        }
        if auth == nil || auth == .password {
            list.append(.promptPassword)
        }

        // The Keychain's password for the resolved user (Tabby's
        // populateStoredPasswordsForResolvedUsername).
        guard let stored = storedPassword else { return list }
        if auth == nil || auth == .password, !list.contains(.savedPassword(stored)) {
            list.insert(.savedPassword(stored), at: list.firstIndex(of: .promptPassword) ?? list.count)
        }
        if auth == nil || auth == .keyboardInteractive, !list.contains(.keyboardInteractive(savedPassword: stored)) {
            if let index = list.firstIndex(of: .keyboardInteractive(savedPassword: nil)) {
                list[index] = .keyboardInteractive(savedPassword: stored)
            } else {
                list.append(.keyboardInteractive(savedPassword: stored))
            }
        }
        return list
    }

    /// The next step to try (removed from the plan), or nil when none is left.
    public mutating func next() -> SSHAuthStep? {
        let index = allowed.isEmpty ? remaining.indices.first : remaining.firstIndex { allowed.contains($0.method) }
        guard let index else { return nil }
        return remaining.remove(at: index)
    }

    /// The server refused the last step. `allowedMethods` is what it still accepts; an empty
    /// list keeps the previous one.
    public mutating func failed(partialSuccess: Bool, allowedMethods: [String]) {
        if partialSuccess {
            for method in allowedMethods where method == "keyboard-interactive" && !remaining.contains(where: { $0.method == method }) {
                remaining.append(.keyboardInteractive(savedPassword: nil))
            }
        }
        if !allowedMethods.isEmpty { allowed = allowedMethods }
    }
}
