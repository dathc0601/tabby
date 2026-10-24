import Foundation

/// Layered configuration, a port of Tabby's `ConfigService` + `ConfigProxy`
/// (`tabby-core/src/services/config.service.ts`).
///
/// - `defaults` come from the bundled `defaults.yaml`.
/// - `user` is the raw content of `config.yaml` and only ever holds values that differ from
///   the defaults.
///
/// A mapping in the defaults is *structural* when it is non-empty and not marked
/// `__nonStructural: true`; structural mappings are merged key by key. Everything else
/// (scalars, arrays, non-structural mappings such as `hotkeys.profile` or
/// `profileDefaults`) is a *leaf*: the user value, when present, replaces the default.
/// Keys that the defaults don't know about are kept as-is.
public final class ConfigStore {
    public private(set) var defaults: ConfigValue
    public private(set) var user: ConfigValue

    private var observers: [UUID: () -> Void] = [:]

    public init(defaults: ConfigValue, user: ConfigValue = .emptyObject) {
        self.defaults = defaults
        self.user = user.objectValue == nil ? .emptyObject : user
        Migrations.migrate(&self.user)
    }

    /// Defaults bundled with TabbyCore.
    public static func bundledDefaults() throws -> ConfigValue {
        guard let url = Bundle.module.url(forResource: "defaults", withExtension: "yaml") else {
            throw ConfigError.missingDefaults
        }
        return try YAMLCoding.parse(String(contentsOf: url, encoding: .utf8))
    }

    // MARK: Structural rules

    static func isStructural(_ v: ConfigValue?) -> Bool {
        guard let o = v?.objectValue else { return false }
        return !o.isEmpty && o[ConfigValue.nonStructuralKey]?.boolValue != true
    }

    // MARK: Reading

    /// The effective value at a dotted path.
    public func value(_ path: String) -> ConfigValue? {
        value(at: ConfigValue.split(path))
    }

    public func value(at path: [String]) -> ConfigValue? {
        Self.resolve(path: path[...], defaults: defaults, user: user)
    }

    private static func resolve(path: ArraySlice<String>, defaults: ConfigValue?, user: ConfigValue?) -> ConfigValue? {
        guard let key = path.first else {
            return effective(defaults: defaults, user: user)
        }
        let d = defaults?[key]
        let u = user?[key]
        if isStructural(d) {
            return resolve(path: path.dropFirst(), defaults: d, user: u)
        }
        // Leaf (or unknown key): the user value wins entirely.
        let leaf = u ?? d?.strippingMarkers()
        return leaf?.value(at: Array(path.dropFirst()))
    }

    /// Merges a structural subtree for presentation (e.g. "all hotkeys").
    private static func effective(defaults: ConfigValue?, user: ConfigValue?) -> ConfigValue? {
        guard isStructural(defaults), let d = defaults?.objectValue else {
            return user ?? defaults?.strippingMarkers()
        }
        var result: [String: ConfigValue] = [:]
        for (k, dv) in d where k != ConfigValue.nonStructuralKey {
            result[k] = effective(defaults: dv, user: user?[k]) ?? dv.strippingMarkers()
        }
        for (k, uv) in user?.objectValue ?? [:] where d[k] == nil {
            result[k] = uv
        }
        return .object(result)
    }

    /// The fully merged configuration.
    public var effective: ConfigValue {
        Self.effective(defaults: defaults, user: user) ?? .emptyObject
    }

    public func defaultValue(_ path: String) -> ConfigValue? {
        defaults.value(at: path)?.strippingMarkers()
    }

    // MARK: Writing

    /// Sets the value at a dotted path. Setting a leaf to its default removes it from `user`,
    /// exactly like `ConfigProxy.__setValue`. Writing below a leaf (e.g.
    /// `hotkeys.profile.<id>`) rewrites the whole leaf.
    public func set(_ path: String, _ value: ConfigValue?) {
        set(at: ConfigValue.split(path), value)
    }

    public func set(at path: [String], _ value: ConfigValue?) {
        guard !path.isEmpty else { return }
        var leafPath: [String] = []
        var d: ConfigValue? = defaults
        var index = 0
        while index < path.count {
            let key = path[index]
            leafPath.append(key)
            let next = d?[key]
            if Self.isStructural(next) && index < path.count - 1 {
                d = next
                index += 1
                continue
            }
            d = next
            break
        }
        let remainder = Array(path.dropFirst(leafPath.count))
        let defaultLeaf = d?.strippingMarkers()
        var newLeaf: ConfigValue?
        if remainder.isEmpty {
            newLeaf = value
        } else {
            var current = user.value(at: leafPath) ?? defaultLeaf ?? .emptyObject
            current.setValue(value, at: remainder)
            newLeaf = current
        }
        if let newLeaf, newLeaf != defaultLeaf {
            user.setValue(newLeaf, at: leafPath)
        } else {
            user.setValue(nil, at: leafPath)
            pruneEmptyObjects(along: Array(leafPath.dropLast()))
        }
        notify()
    }

    /// Replaces the user layer wholesale (e.g. from the raw YAML editor). An empty document means
    /// defaults, as in Tabby; any other value that is not a map is refused, so a stray word or
    /// list can't wipe every setting and profile.
    public func replaceUser(_ newUser: ConfigValue) throws {
        guard newUser.objectValue != nil || newUser == .null else { throw ConfigError.notAMap }
        user = newUser.objectValue == nil ? .emptyObject : newUser
        Migrations.migrate(&user)
        notify()
    }

    private func pruneEmptyObjects(along path: [String]) {
        var p = path
        while !p.isEmpty {
            if let o = user.value(at: p)?.objectValue, o.isEmpty {
                user.setValue(nil, at: p)
                p.removeLast()
            } else {
                break
            }
        }
    }

    // MARK: Typed helpers

    public func string(_ path: String) -> String? { value(path)?.stringValue }
    public func bool(_ path: String) -> Bool { value(path)?.boolValue ?? false }
    public func double(_ path: String) -> Double? { value(path)?.doubleValue }
    public func int(_ path: String) -> Int? { value(path)?.intValue }

    public func decode<T: Decodable>(_ type: T.Type, at path: String) -> T? {
        guard let v = value(path) else { return nil }
        return try? v.decode(T.self)
    }

    // MARK: Persistence

    public func serializedUserConfig() throws -> String {
        try YAMLCoding.serialize(user)
    }

    // MARK: Observation

    @discardableResult
    public func observe(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = handler
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func notify() {
        for handler in observers.values { handler() }
    }
}

public enum ConfigError: Error, LocalizedError {
    case missingDefaults
    case invalidYAML(String)
    case notAMap

    public var errorDescription: String? {
        switch self {
        case .missingDefaults: return L("The bundled defaults.yaml is missing.")
        case .invalidYAML(let msg): return L("The configuration is not valid YAML: {msg}", ["msg": msg])
        case .notAMap: return L("The configuration must be a map of settings (key: value).")
        }
    }
}
