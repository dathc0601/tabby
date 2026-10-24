import Foundation

/// How an SSH profile reaches its host (Tabby's `connectionMode` in
/// `sshProfileSettings.component.ts`).
public enum SSHConnectionMode: String, CaseIterable, Sendable {
    case direct, proxyCommand, jumpHost, socksProxy, httpProxy

    /// The options each mode owns.
    static let keys: [SSHConnectionMode: [String]] = [
        .proxyCommand: ["proxyCommand"], .jumpHost: ["jumpHost"],
        .socksProxy: ["socksProxyHost", "socksProxyPort"], .httpProxy: ["httpProxyHost", "httpProxyPort"],
    ]

    /// The mode a profile is in, checked in Tabby's order.
    public init(options: ConfigValue) {
        func set(_ key: String) -> Bool {
            guard let v = options[key], !v.isNull else { return false }
            return !(v.stringValue ?? "x").isEmpty
        }
        if set("proxyCommand") { self = .proxyCommand }
        else if set("jumpHost") { self = .jumpHost }
        else if set("socksProxyHost") { self = .socksProxy }
        else if set("httpProxyHost") { self = .httpProxy }
        else { self = .direct }
    }

    /// Removes the options of the other modes, as Tabby does when the profile is saved.
    public func apply(to options: inout ConfigValue) {
        for (mode, keys) in Self.keys where mode != self {
            for key in keys { options[key] = nil }
        }
    }
}
