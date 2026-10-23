import Foundation

/// The strings of the current language. `L()` reads it from any thread (session messages
/// are written off the main thread), so the catalog sits behind a lock.
public enum L10n {
    /// Catalog layers, searched in order: TabbyMac's own catalog, then Tabby's. A key with no
    /// exact entry is matched ignoring case and a trailing "…", "..." or ":" (menu items end
    /// in "…", Tabby writes "New Tab" where TabbyMac writes "New tab"), and keeps its own
    /// ending.
    public struct Catalog: Sendable {
        public let layers: [[String: String]]
        private let folded: [[String: String]]

        public init(layers: [[String: String]]) {
            self.layers = layers
            folded = layers.map { layer in
                var index: [String: String] = [:]
                for (key, value) in layer.sorted(by: { $0.key < $1.key }) {
                    let core = Self.normalize(key).core
                    if index[core] == nil { index[core] = Self.trimEnding(value) }
                }
                return index
            }
        }
        public static let empty = Catalog(layers: [])

        public func lookup(_ key: String) -> String? {
            for layer in layers { if let value = layer[key] { return value } }
            let (core, ending) = Self.normalize(key)
            for index in folded { if let value = index[core] { return value + ending } }
            return nil
        }

        static let endings = ["…", "...", ":", "："]

        /// The lowercased text without its trailing ellipsis or colon, and that ending.
        public static func normalize(_ key: String) -> (core: String, ending: String) {
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            for ending in endings where trimmed.hasSuffix(ending) {
                return (String(trimmed.dropLast(ending.count)).trimmingCharacters(in: .whitespaces).lowercased(), ending)
            }
            return (trimmed.lowercased(), "")
        }

        static func trimEnding(_ text: String) -> String {
            for ending in endings where text.hasSuffix(ending) { return String(text.dropLast(ending.count)) }
            return text
        }

        /// The normalized forms of `keys`, for deciding whether a catalog covers a key.
        public static func normalizedKeys<S: Sequence>(_ keys: S) -> Set<String> where S.Element == String {
            Set(keys.map { normalize($0).core })
        }
    }

    /// Where a bundled catalog comes from (`Resources/locale/<source>/<code>.po`).
    public enum Source: String, Sendable { case tabby, tabbymac }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var catalog = Catalog.empty
        var language: String?
    }
    private static let state = State()

    /// The loaded language code; `nil` is English without a catalog.
    public static var language: String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.language
    }

    /// Loads the bundled catalogs for `code` (nil: English).
    public static func load(language code: String?) {
        guard let code else { install(.empty, language: nil); return }
        let layers = [bundledEntries(code, source: .tabbymac), bundledEntries(code, source: .tabby)].filter { !$0.isEmpty }
        install(Catalog(layers: layers), language: code)
    }

    public static func install(_ catalog: Catalog, language: String?) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.catalog = catalog
        state.language = language
    }

    public static func translation(_ key: String) -> String? {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.catalog.lookup(key)
    }

    public static func bundledEntries(_ code: String, source: Source) -> [String: String] {
        guard let url = bundledURL(code, source: source),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return POCatalog.parse(text)
    }

    public static func bundledURL(_ name: String, source: Source, extension ext: String = "po") -> URL? {
        guard let dir = Bundle.module.url(forResource: "locale", withExtension: nil) else { return nil }
        let url = dir.appendingPathComponent(source.rawValue).appendingPathComponent("\(name).\(ext)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// The current language's text for `key` (the English text, Tabby's msgid), with `{name}`
/// placeholders filled from `args`. Falls back to the English text. Keys are static text so
/// the catalog test can find them (`Tests/TabbyCoreTests/CatalogTests.swift`).
public func L(_ key: String, _ args: [String: CustomStringConvertible] = [:]) -> String {
    var text = L10n.translation(key) ?? key
    for (name, value) in args {
        text = text.replacingOccurrences(of: "{\(name)}", with: value.description)
    }
    return text
}

/// Marks a catalog key that is translated where it is shown (`L(name)`), like Tabby's `_()`
/// marker: hotkey names, settings sections.
public func Lkey(_ key: String) -> String { key }
