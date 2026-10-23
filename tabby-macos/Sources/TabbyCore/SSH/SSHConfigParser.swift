import Foundation

/// Reads `~/.ssh/config` Host blocks into built-in SSH profiles, like Tabby's
/// `OpenSSHImporter` (`tabby-electron/src/sshImporters.ts`). Wildcard hosts are skipped.
public enum SSHConfigParser {
    public struct HostEntry: Hashable, Sendable {
        public var alias: String
        public var options: [String: [String]]

        public func first(_ key: String) -> String? { options[key.lowercased()]?.first }
    }

    public static func parse(_ text: String) -> [HostEntry] {
        var entries: [HostEntry] = []
        var current: [HostEntry] = []
        var global: [String: [String]] = [:]
        var inMatch = false

        func flush() {
            entries.append(contentsOf: current)
            current = []
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }
            let (key, value) = splitKeyValue(line)
            let lower = key.lowercased()
            if lower == "host" {
                flush()
                inMatch = false
                let aliases = tokenize(value)
                current = aliases.map { HostEntry(alias: $0, options: global) }
            } else if lower == "match" {
                flush()
                inMatch = true
            } else if inMatch {
                continue
            } else if current.isEmpty {
                global[lower, default: []].append(value)
            } else {
                for i in current.indices {
                    // ssh uses the first obtained value, except for repeatable keys.
                    // Options before the first Host line were obtained first, so they win.
                    if repeatable.contains(lower) {
                        current[i].options[lower, default: []].append(value)
                    } else if current[i].options[lower] == nil {
                        current[i].options[lower] = [value]
                    }
                }
            }
        }
        flush()
        return entries.filter { !$0.alias.contains("*") && !$0.alias.contains("?") && !$0.alias.hasPrefix("!") }
    }

    static let repeatable: Set<String> = ["identityfile", "localforward", "remoteforward", "dynamicforward", "certificatefile"]

    static func splitKeyValue(_ line: String) -> (String, String) {
        if let eq = line.firstIndex(of: "="), !line[..<eq].contains(" ") {
            return (String(line[..<eq]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces))
        }
        let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let key = parts.first.map(String.init) ?? ""
        let value = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        return (key, value.hasPrefix("=") ? String(value.dropFirst()).trimmingCharacters(in: .whitespaces) : value)
    }

    static func tokenize(_ value: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in value {
            if ch == "\"" { quoted.toggle(); continue }
            if (ch == " " || ch == "\t") && !quoted {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Converts parsed hosts into built-in SSH profiles (`ssh:ssh-config:<alias>`).
    public static func profiles(from entries: [HostEntry], homeDirectory: String = NSHomeDirectory()) -> [Profile] {
        let byAlias = Dictionary(entries.map { ($0.alias, $0) }, uniquingKeysWith: { a, _ in a })
        return entries.map { e in
            var options: [String: ConfigValue] = ["host": .string(e.first("hostname") ?? e.alias)]
            if let port = e.first("port").flatMap(Int.init) { options["port"] = .int(port) }
            options["user"] = .string(e.first("user") ?? NSUserName())
            if let keys = e.options["identityfile"] {
                options["privateKeys"] = .array(keys.map { .string(expandTilde($0, home: homeDirectory)) })
            }
            if let jump = e.first("proxyjump"), jump.lowercased() != "none" {
                let firstHop = jump.split(separator: ",").first.map(String.init) ?? jump
                let hopAlias = firstHop.split(separator: "@").last.map(String.init) ?? firstHop
                let hopName = hopAlias.split(separator: ":").first.map(String.init) ?? hopAlias
                if byAlias[hopName] != nil {
                    options["jumpHost"] = .string("ssh:ssh-config:\(Slug.make(hopName))")
                } else {
                    options["proxyCommand"] = .string("ssh -W %h:%p \(firstHop)") // l10n-ignore: a command line
                }
            }
            if let pc = e.first("proxycommand"), pc.lowercased() != "none" { options["proxyCommand"] = .string(pc) }
            if e.first("forwardagent")?.lowercased() == "yes" { options["agentForward"] = true }
            if e.first("forwardx11")?.lowercased() == "yes" { options["x11"] = true }
            if let i = e.first("serveraliveinterval").flatMap(Int.init) { options["keepaliveInterval"] = .int(i * 1000) }
            if let c = e.first("serveralivecountmax").flatMap(Int.init) { options["keepaliveCountMax"] = .int(c) }
            if let t = e.first("connecttimeout").flatMap(Int.init) { options["readyTimeout"] = .int(t * 1000) }
            var forwards: [ConfigValue] = []
            for spec in e.options["localforward"] ?? [] {
                if let f = parseForward(spec, type: .local) { forwards.append(f.configValue) }
            }
            for spec in e.options["remoteforward"] ?? [] {
                if let f = parseForward(spec, type: .remote) { forwards.append(f.configValue) }
            }
            for spec in e.options["dynamicforward"] ?? [] {
                if let f = parseForward(spec, type: .dynamic) { forwards.append(f.configValue) }
            }
            if !forwards.isEmpty { options["forwardedPorts"] = .array(forwards) }
            return Profile(
                id: "ssh:ssh-config:\(Slug.make(e.alias))",
                type: "ssh",
                name: e.alias,
                group: L("Imported from .ssh/config"),
                options: .object(options),
                isBuiltin: true,
                extra: ["sshConfigAlias": .string(e.alias)]
            )
        }
    }

    static func expandTilde(_ path: String, home: String) -> String {
        path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
    }

    /// Parses `[bind:]port host:hostport` (local/remote) or `[bind:]port` (dynamic).
    static func parseForward(_ spec: String, type: PortForwardType) -> ForwardedPort? {
        let parts = tokenize(spec)
        guard let listen = parts.first else { return nil }
        let (bind, port) = splitHostPort(listen, defaultHost: "127.0.0.1")
        guard let port else { return nil }
        if type == .dynamic {
            return ForwardedPort(type: .dynamic, host: bind, port: port)
        }
        guard parts.count > 1 else { return nil }
        let (target, targetPort) = splitHostPort(parts[1], defaultHost: "localhost")
        guard let targetPort else { return nil }
        return ForwardedPort(type: type, host: bind, port: port, targetAddress: target, targetPort: targetPort)
    }

    static func splitHostPort(_ s: String, defaultHost: String) -> (String, Int?) {
        if s.hasPrefix("[") , let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil)
        }
        if let colon = s.lastIndex(of: ":") {
            return (String(s[..<colon]), Int(s[s.index(after: colon)...]))
        }
        return (defaultHost, Int(s))
    }
}
