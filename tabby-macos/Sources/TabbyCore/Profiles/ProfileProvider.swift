import Foundation

/// The data half of a Tabby `ProfileProvider`: defaults, built-in profiles and quick
/// connect. Session creation lives in the platform layer.
public protocol ProfileProvider: AnyObject {
    /// Profile `type`, e.g. `local` or `ssh`.
    var id: String { get }
    /// Display name, e.g. "Local terminal".
    var name: String { get }
    /// Provider-level profile defaults (`configDefaults` in Tabby), e.g. `{options: {port: 22}}`.
    var configDefaults: ConfigValue { get }
    var supportsQuickConnect: Bool { get }

    func builtinProfiles() -> [Profile]
    func quickConnect(_ query: String) -> Profile?
    func description(for profile: Profile) -> String
    func suggestedName(for profile: Profile) -> String?
}

public extension ProfileProvider {
    var supportsQuickConnect: Bool { false }
    func quickConnect(_ query: String) -> Profile? { nil }
    func description(for profile: Profile) -> String { "" }
    func suggestedName(for profile: Profile) -> String? { nil }
}

/// A detected shell (Tabby's `Shell`, from `tabby-electron/src/shells/*`).
public struct Shell: Hashable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var args: [String]
    public var hidden: Bool

    public init(id: String, name: String, command: String, args: [String], hidden: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.hidden = hidden
    }

    /// Shells listed in an `/etc/shells` file, one profile per entry, launched with `-l`
    /// (port of `POSIXShellsProvider`).
    public static func parseEtcShells(_ text: String) -> [Shell] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
            .map { path in
                Shell(id: Slug.make(path), name: path, command: path, args: ["-l"])
            }
    }
}

/// `local` profiles: the OS default login shell plus one per detected shell.
public final class LocalProfileProvider: ProfileProvider {
    public let id = "local"
    public var name: String { L("Local terminal") }
    public let configDefaults: ConfigValue = [
        "options": [
            "command": "",
            "args": [],
            "cwd": nil,
            "env": ["__nonStructural": true],
            "pauseAfterExit": false,
        ],
    ]

    private let shellsProvider: () -> [Shell]

    public init(shells: @escaping () -> [Shell]) {
        self.shellsProvider = shells
    }

    public func builtinProfiles() -> [Profile] {
        shellsProvider().map { shell in
            Profile(
                id: "local:\(shell.id)",
                type: "local",
                name: shell.name,
                options: LocalOptions(command: shell.command, args: shell.args).configValue,
                icon: shell.id == "default" ? "terminal" : nil,
                isBuiltin: true,
                extra: shell.hidden ? ["hidden": true] : [:]
            )
        }
    }

    public func description(for profile: Profile) -> String {
        LocalOptions(profile.options).command
    }
}
