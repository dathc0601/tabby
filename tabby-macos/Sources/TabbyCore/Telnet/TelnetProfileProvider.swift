import Foundation

/// Options of a `telnet` profile (`TelnetProfileOptions` in `tabby-telnet/src/session.ts`);
/// stream processing is read with `StreamOptions`, login scripts by the pane.
public struct TelnetOptions: Hashable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int = 23) {
        self.host = host
        self.port = port
    }

    public init(_ v: ConfigValue) {
        host = v["host"]?.stringValue ?? ""
        port = v["port"]?.intValue ?? 23
    }
}

/// `telnet` profiles: the telnet and raw-socket templates and quick connect. Port of
/// `tabby-telnet/src/profiles.ts`.
public final class TelnetProfileProvider: ProfileProvider {
    public let id = "telnet"
    public var name: String { L("Telnet") }
    public let supportsQuickConnect = true

    public let configDefaults: ConfigValue = [
        "options": [
            "host": nil, "port": 23, "inputMode": "local-echo", "outputMode": nil, "inputNewlines": nil,
            "outputNewlines": "crlf", "scripts": [], "input": ["backspace": "backspace"],
        ],
        "clearServiceMessagesOnConnect": false,
    ]

    public init() {}

    public func builtinProfiles() -> [Profile] {
        [
            Profile(id: "telnet:template", type: "telnet", name: L("Telnet session"),
                    options: ["host": "", "port": 23, "inputMode": "readline", "outputMode": nil,
                              "inputNewlines": nil, "outputNewlines": "crlf"],
                    icon: "fas fa-network-wired", isBuiltin: true, isTemplate: true), // l10n-ignore: an icon name
            Profile(id: "socket:template", type: "telnet", name: L("Raw socket connection"),
                    options: ["host": "", "port": 1234],
                    icon: "fas fa-network-wired", isBuiltin: true, isTemplate: true), // l10n-ignore: an icon name
        ]
    }

    /// `host`, `host:port` or `[v6]:port` (Tabby can't parse a bracketed host without a port).
    public func quickConnect(_ query: String) -> Profile? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        var host = q
        var port = 23
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            let rest = host[host.index(after: close)...]
            if !rest.isEmpty {
                guard rest.hasPrefix(":"), let p = Int(rest.dropFirst()) else { return nil }
                port = p
            }
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            guard let p = Int(host[host.index(after: colon)...]) else { return nil }
            port = p
            host = String(host[..<colon])
        }
        guard !host.isEmpty, (1...65535).contains(port) else { return nil }
        return Profile(type: "telnet", name: q, options: [
            "host": .string(host), "port": .int(port), "inputMode": "readline", "outputNewlines": "crlf",
        ])
    }

    public func description(for profile: Profile) -> String {
        let options = TelnetOptions(profile.options)
        return options.host.isEmpty ? "" : "\(options.host):\(options.port)"
    }

    public func suggestedName(for profile: Profile) -> String? {
        let d = description(for: profile)
        return d.isEmpty ? nil : d
    }

    /// The inverse of `quickConnect` (`intoQuickConnectString`), with IPv6 hosts bracketed.
    public static func quickConnectString(_ options: TelnetOptions) -> String {
        var s = options.host.contains(":") ? "[\(options.host)]" : options.host
        if options.port != 23 { s += ":\(options.port)" }
        return s
    }
}
