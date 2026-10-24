// l10n-ignore-file: URL syntax, nothing shown to users.
import Foundation

/// Links the app opens (phase 5):
/// - `tabbymac://<command>?<arguments>`: Tabby's `tabby://` URLs (`app/lib/urlHandler.ts`)
///   under TabbyMac's own scheme, with the yargs argument names (`directory`, `command`,
///   `profileName`, `text`/`escape`, `profileNumber`, `providerId`/`query`); the `tabby`
///   helper hands its requests to the app this way.
/// - `ssh://[user@]host[:port]` (RFC 4248) and `telnet://host[:port]`: a quick-connect tab.
public enum TabbyURL {
    public static let scheme = "tabbymac"

    public static func parse(_ url: URL) -> CLIRequest? {
        switch url.scheme?.lowercased() {
        case "ssh": return link(url, provider: "ssh", withUser: true)
        case "telnet": return link(url, provider: "telnet", withUser: false)
        case scheme: return command(url)
        default: return nil
        }
    }

    // MARK: tabbymac://

    private static func command(_ url: URL) -> CLIRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let name = (components.host?.isEmpty == false ? components.host : nil)
            ?? components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var items: [String: [String]] = [:]
        for item in components.queryItems ?? [] { items[item.name, default: []].append(item.value ?? "") }
        func value(_ key: String) -> String? { items[key]?.first.flatMap { $0.isEmpty ? nil : $0 } }
        /// yargs booleans: `true`, or the bare key.
        func flag(_ key: String) -> Bool { items[key].map { $0.first == "true" || $0.first == "" } ?? false }

        switch name.lowercased() {
        case "open":
            return .open(directory: value("directory"))
        case "run":
            let parts = items["command"] ?? []
            // Tabby's links carry one shell-quoted string; the helper writes one item per
            // argument and always a cwd, so only a cwd-less single item is split.
            let command = parts.count == 1 && items["cwd"] == nil ? ShellWords.split(parts[0]) : parts
            guard !command.isEmpty else { return nil }
            return .run(command: command, cwd: value("cwd"))
        case "profile":
            return value("profileName").map { .profile(name: $0) }
        case "paste":
            return .paste(text: items["text"]?.first, escape: flag("escape"))
        case "recent":
            return (value("profileNumber") ?? value("index")).flatMap(Int.init).flatMap { $0 >= 0 ? .recent(index: $0) : nil }
        case "quickconnect":
            guard let provider = value("providerId"), let query = value("query") else { return nil }
            return .quickConnect(providerId: provider, query: query)
        case "path":
            return value("path").map { .path($0) }
        default:
            return nil
        }
    }

    public static func encode(_ request: CLIRequest) -> URL {
        var host = ""
        var items: [(String, String)] = []
        switch request {
        case let .open(directory):
            host = "open"
            if let directory { items.append(("directory", directory)) }
        case let .run(command, cwd):
            host = "run"
            items += command.map { ("command", $0) }
            if let cwd { items.append(("cwd", cwd)) }
        case let .profile(name):
            host = "profile"
            items.append(("profileName", name))
        case let .paste(text, escape):
            host = "paste"
            if let text { items.append(("text", text)) }
            if escape { items.append(("escape", "true")) }
        case let .recent(index):
            host = "recent"
            items.append(("profileNumber", String(index)))
        case let .quickConnect(provider, query):
            host = "quickConnect"
            items += [("providerId", provider), ("query", query)]
        case let .path(path):
            host = "path"
            items.append(("path", path))
        }
        let query = items.map { "\($0.0)=\(escape($0.1))" }.joined(separator: "&")
        return URL(string: "\(scheme)://\(host)" + (query.isEmpty ? "" : "?\(query)"))!
    }

    /// Percent-encodes everything but unreserved characters and `/`, so `&`, `=`, `+` and
    /// `%` in a value survive.
    private static func escape(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: ssh:// and telnet://

    private static func link(_ url: URL, provider: String, withUser: Bool) -> CLIRequest? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = components.percentEncodedHost?.removingPercentEncoding, !host.isEmpty else { return nil }
        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        var query = host
        if let port = components.port { query += ":\(port)" }
        if withUser, let user = components.user?.split(separator: ";", maxSplits: 1).first.map(String.init), !user.isEmpty {
            query = "\(user)@\(query)"
        }
        return .quickConnect(providerId: provider, query: query)
    }
}
