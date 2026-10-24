// l10n-ignore-file: URL schemes, patterns and config values, nothing shown as text.
import Foundation

/// Tabby's `clickableLinks.modifier` (`tabby-linkifier`): the key a click on a link needs.
public enum LinkModifier: String, Sendable {
    case none, option, shift, command, control

    /// Tabby's values: null, `altKey`, `shiftKey`, `metaKey`, `ctrlKey`.
    public init(config value: String?) {
        switch value {
        case "altKey": self = .option
        case "shiftKey": self = .shift
        case "metaKey": self = .command
        case "ctrlKey": self = .control
        default: self = .none
        }
    }

    public var configValue: String? {
        switch self {
        case .none: return nil
        case .option: return "altKey"
        case .shift: return "shiftKey"
        case .command: return "metaKey"
        case .control: return "ctrlKey"
        }
    }
}

/// What a clicked link opens (Tabby's URL, IP and file handlers).
public enum LinkTarget: Equatable, Sendable {
    /// A URL for the default app (browser, mail).
    case web(String)
    /// An `ssh://` or `telnet://` link: a quick-connect tab.
    case quickConnect(String)
    /// A file on this Mac, opened in its default app.
    case file(String)

    /// ★ Only these schemes are handed over: an OSC 8 link can hide any URL behind its text.
    static let webSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    /// - Parameters:
    ///   - cwd: the pane's folder, for relative paths.
    ///   - local: whether the pane runs on this Mac; a remote pane's paths are not followed.
    public static func resolve(_ raw: String, cwd: String?, home: String, local: Bool,
                               fileExists: (String) -> Bool) -> LinkTarget? {
        let link = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return nil }
        if let scheme = scheme(of: link) {
            switch scheme {
            case _ where webSchemes.contains(scheme): return .web(link)
            case "ssh", "telnet": return .quickConnect(link)
            case "file":
                guard let url = URL(string: link), url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
                return local && fileExists(url.path) ? .file(url.path) : nil
            default: return nil
            }
        }
        if matches(link, LinkDetector.ipv4, whole: true) || matches(link, LinkDetector.www, whole: true) {
            return .web("http://" + link)
        }
        guard local else { return nil }
        var path = link.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
        if path == "~" || path.hasPrefix("~/") {
            path = home + path.dropFirst()
        } else if !path.hasPrefix("/") {
            guard let cwd else { return nil }
            path = (cwd as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        return fileExists(path) ? .file(path) : nil
    }

    /// `scheme://…`, or one of the schemes written without slashes.
    static func scheme(of link: String) -> String? {
        guard let colon = link.firstIndex(of: ":") else { return nil }
        let name = link[..<colon].lowercased()
        guard let first = name.first, first.isLetter,
              name.allSatisfy({ $0.isLetter || $0.isNumber || "+.-".contains($0) }) else { return nil }
        if link[colon...].hasPrefix("://") || ["mailto", "tel", "news", "magnet"].contains(name) { return String(name) }
        return nil
    }

    static func matches(_ text: String, _ pattern: String, whole: Bool) -> Bool {
        guard let re = try? NSRegularExpression(pattern: whole ? "^(?:\(pattern))$" : pattern) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// The link forms SwiftTerm doesn't detect (Tabby's `IPHandler` and its URL handler's
/// `www.` form), found around a clicked column.
public enum LinkDetector {
    static let ipv4 = #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\.?\d)(?::\d{1,5})?(?:/[^\s'"<>()]*)?"#
    static let www = #"(?<![\w.])www\.[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?::\d{1,5})?(?:/[^\s'"<>()]*)?"#
    /// The links that open a quick-connect tab. SwiftTerm has no `telnet:` in its schemes and
    /// reads the rest of such a link as the path `//host:port`.
    static let scheme = #"(?<![\w+.-])(?:telnet|ssh)://[^\s'"<>()]*[^\s'"<>().,;:!?]"#

    /// The address, `www.` or `telnet://`/`ssh://` link that covers character `column` of `line`.
    public static func match(in line: String, at column: Int) -> String? {
        first(of: [scheme, ipv4, www], in: line, at: column)
    }

    /// The `telnet://` or `ssh://` link that covers character `column` of `line`.
    public static func schemeLink(in line: String, at column: Int) -> String? {
        first(of: [scheme], in: line, at: column)
    }

    private static func first(of patterns: [String], in line: String, at column: Int) -> String? {
        guard column >= 0, column < line.count else { return nil }
        let index = line.index(line.startIndex, offsetBy: column)
        let utf16 = index.utf16Offset(in: line)
        let ns = NSRange(line.startIndex..., in: line)
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            for m in re.matches(in: line, range: ns) where NSLocationInRange(utf16, m.range) {
                return Range(m.range, in: line).map { String(line[$0]) }
            }
        }
        return nil
    }
}
