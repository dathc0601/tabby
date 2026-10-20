import Foundation

/// `ssh` profiles: defaults, the template, `~/.ssh/config` imports and quick connect.
/// Port of `tabby-ssh/src/profiles.ts`.
public final class SSHProfileProvider: ProfileProvider {
    public let id = "ssh"
    public let name = "SSH connection"
    public let supportsQuickConnect = true

    public let configDefaults: ConfigValue = [
        "options": [
            "host": "", "port": 22, "user": "root", "auth": nil, "password": nil, "privateKeys": [],
            "keepaliveInterval": 5000, "keepaliveCountMax": 10, "readyTimeout": nil, "x11": false,
            "skipBanner": false, "jumpHost": nil, "agentForward": false, "warnOnClose": nil,
            "algorithms": ["hmac": [], "kex": [], "cipher": [], "serverHostKey": [], "compression": []],
            "proxyCommand": nil, "forwardedPorts": [], "scripts": [], "socksProxyHost": nil,
            "socksProxyPort": nil, "httpProxyHost": nil, "httpProxyPort": nil, "reuseSession": true,
            "input": ["backspace": "backspace"], "cwd": nil, "rememberCwd": false, "term": "xterm-256color",
        ],
        "clearServiceMessagesOnConnect": true,
    ]

    private let sshConfigLoader: () -> String?

    /// - Parameter sshConfig: returns the text of `~/.ssh/config`, or nil.
    public init(sshConfig: @escaping () -> String? = { nil }) {
        self.sshConfigLoader = sshConfig
    }

    public func builtinProfiles() -> [Profile] {
        var list = [
            Profile(id: "ssh:template", type: "ssh", name: "SSH connection", options: ["host": "", "port": 22, "user": "root"],
                    icon: "network", isBuiltin: true, isTemplate: true),
        ]
        if let text = sshConfigLoader() {
            list += SSHConfigParser.profiles(from: SSHConfigParser.parse(text))
        }
        return list
    }

    public func quickConnect(_ query: String) -> Profile? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        var user: String?
        var host = q
        var port = 22
        if let at = host.lastIndex(of: "@") {
            user = String(host[..<at])
            host = String(host[host.index(after: at)...])
        }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let rest = host[host.index(after: close)...]
            if rest.hasPrefix(":"), let p = Int(rest.dropFirst()) { port = p }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if let colon = host.firstIndex(of: ":") {
            if let p = Int(host[host.index(after: colon)...]) { port = p }
            host = String(host[..<colon])
        }
        guard !host.isEmpty else { return nil }
        var options: [String: ConfigValue] = ["host": .string(host), "port": .int(port)]
        if let user, !user.isEmpty { options["user"] = .string(user) }
        return Profile(type: "ssh", name: q, options: .object(options))
    }

    public func description(for profile: Profile) -> String {
        profile.options["host"]?.stringValue ?? ""
    }

    public func suggestedName(for profile: Profile) -> String? {
        SSHOptions(profile.options).suggestedName
    }

    /// The inverse of `quickConnect` (`intoQuickConnectString`).
    public static func quickConnectString(_ options: SSHOptions) -> String {
        var s = options.host.contains(":") ? "[\(options.host)]" : options.host
        if options.user != "root" { s = "\(options.user)@\(s)" }
        if options.port != 22 { s += ":\(options.port)" }
        return s
    }
}
