import Foundation

/// Reads gettext `.po` catalogs as Tabby writes them (`../locale/*.po`): `msgid` is the
/// English text, `msgstr` its translation. Untranslated (empty) and `#, fuzzy` entries are
/// left out, so the lookup falls back to English for them.
public enum POCatalog {
    /// The lookup key of an entry with a `msgctxt` (gettext's convention: context, EOT, id).
    public static func key(_ msgid: String, context: String?) -> String {
        context.map { "\($0)\u{04}\(msgid)" } ?? msgid
    }

    public struct Entry: Equatable, Sendable {
        public var context: String?
        public var id: String
        public var translation: String
        public var fuzzy: Bool
    }

    /// The usable translations: not empty, not fuzzy, and ★ not renaming a placeholder
    /// (Tabby's Swedish catalog has `{nummer}` for `{number}`, which would print as is), so
    /// such an entry falls back to English.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for e in entries(text) where !e.id.isEmpty && !e.translation.isEmpty && !e.fuzzy
            && placeholders(e.translation).isSubset(of: placeholders(e.id)) {
            result[key(e.id, context: e.context)] = e.translation
        }
        return result
    }

    /// The `{name}` placeholders of a message.
    public static func placeholders(_ text: String) -> Set<String> {
        var names: Set<String> = []
        var current: String?
        for ch in text {
            if ch == "{" { current = "" }
            else if ch == "}" { if let c = current, !c.isEmpty { names.insert(c) }; current = nil }
            else if current != nil {
                if ch.isLetter || ch.isNumber || ch == "_" { current?.append(ch) } else { current = nil }
            }
        }
        return names
    }

    /// Every entry of a catalog, untranslated ones included (the header has an empty id).
    public static func entries(_ text: String) -> [Entry] {
        enum Field { case context, id, idPlural, str, otherStr }
        var result: [Entry] = []
        var context: String?
        var id: String?
        var str: String?
        var field: Field?
        var fuzzy = false
        var pendingFuzzy = false

        func flush() {
            if let id { result.append(Entry(context: context, id: id, translation: str ?? "", fuzzy: fuzzy)) }
            context = nil; id = nil; str = nil; field = nil; fuzzy = false
        }
        /// A `msgctxt` or `msgid` that starts a new entry.
        func begin() {
            if str != nil { flush() }
            if field == nil { fuzzy = pendingFuzzy; pendingFuzzy = false }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                if str != nil { flush() }
                if line.hasPrefix("#,") && line.contains("fuzzy") { pendingFuzzy = true }
                continue
            }
            if line.hasPrefix("\"") {
                let piece = unquote(line)
                switch field {
                case .context: context = (context ?? "") + piece
                case .id: id = (id ?? "") + piece
                case .str: str = (str ?? "") + piece
                default: break
                }
                continue
            }
            if line.hasPrefix("msgctxt") {
                begin(); context = unquote(line); field = .context
            } else if line.hasPrefix("msgid_plural") {
                field = .idPlural
            } else if line.hasPrefix("msgid") {
                if field != .context { begin() }
                id = unquote(line); field = .id
            } else if line.hasPrefix("msgstr[0]") || line.hasPrefix("msgstr ") {
                str = unquote(line); field = .str
            } else if line.hasPrefix("msgstr[") {
                field = .otherStr
            }
        }
        flush()
        return result
    }

    /// The text between the first and the last quote, with C escapes resolved.
    static func unquote(_ line: String) -> String {
        guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return "" }
        var out = ""
        var escaped = false
        for ch in line[line.index(after: open)..<close] {
            if escaped {
                switch ch {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else {
                out.append(ch)
            }
        }
        return out
    }
}
