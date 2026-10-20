import Foundation

/// A dynamically typed, YAML/JSON-compatible value.
///
/// Tabby's configuration is free-form YAML that plugins extend at will, so the clone keeps it
/// as a tree of `ConfigValue`s and offers typed views on top. Unknown keys survive a
/// load/save round trip unchanged.
public enum ConfigValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ConfigValue])
    case object([String: ConfigValue])

    public static let emptyObject = ConfigValue.object([:])

    // MARK: Accessors

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "on": return true
            case "false", "no", "off": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    /// The string form of scalars. Booleans and numbers are rendered as YAML would print them.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var arrayValue: [ConfigValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: ConfigValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var stringArrayValue: [String]? {
        arrayValue?.compactMap { $0.stringValue }
    }

    public subscript(key: String) -> ConfigValue? {
        get { objectValue?[key] }
        set {
            var o = objectValue ?? [:]
            o[key] = newValue
            self = .object(o)
        }
    }

    // MARK: Paths

    /// Reads a dotted path such as `terminal.fontSize`.
    public func value(at path: String) -> ConfigValue? {
        value(at: ConfigValue.split(path))
    }

    public func value(at path: [String]) -> ConfigValue? {
        var current: ConfigValue = self
        for component in path {
            guard let next = current[component] else { return nil }
            current = next
        }
        return current
    }

    /// Writes at a path, creating intermediate objects. Passing `nil` removes the key.
    public mutating func setValue(_ value: ConfigValue?, at path: [String]) {
        guard let first = path.first else {
            self = value ?? .null
            return
        }
        if path.count == 1 {
            self[first] = value
            return
        }
        var child = self[first] ?? .emptyObject
        if child.objectValue == nil { child = .emptyObject }
        child.setValue(value, at: Array(path.dropFirst()))
        self[first] = child
    }

    public mutating func setValue(_ value: ConfigValue?, at path: String) {
        setValue(value, at: ConfigValue.split(path))
    }

    static func split(_ path: String) -> [String] {
        path.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Merging

    /// Deep merge in the style of Tabby's `configMerge`: objects merge key by key, everything
    /// else (including arrays) in `other` replaces the value in `self`.
    public func merged(with other: ConfigValue) -> ConfigValue {
        guard case .object(var base) = self, case .object(let overlay) = other else {
            return other
        }
        for (key, value) in overlay {
            if let existing = base[key] {
                base[key] = existing.merged(with: value)
            } else {
                base[key] = value
            }
        }
        return .object(base)
    }

    /// Removes every `__nonStructural` marker, recursively.
    public func strippingMarkers() -> ConfigValue {
        switch self {
        case .object(let o):
            var r: [String: ConfigValue] = [:]
            for (k, v) in o where k != ConfigValue.nonStructuralKey {
                r[k] = v.strippingMarkers()
            }
            return .object(r)
        case .array(let a):
            return .array(a.map { $0.strippingMarkers() })
        default:
            return self
        }
    }

    public static let nonStructuralKey = "__nonStructural"
}

// MARK: - Literals

extension ConfigValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: ConfigValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, ConfigValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Codable bridge

extension ConfigValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? c.decode(Int.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) {
            self = .double(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([ConfigValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: ConfigValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// Decodes a typed struct from this value (via JSON). Missing keys fall back to the struct's
    /// own decoding logic, so types should use `decodeIfPresent` with defaults.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Encodes a typed value into a `ConfigValue` tree.
    public static func encode<T: Encodable>(_ value: T) throws -> ConfigValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ConfigValue.self, from: data)
    }
}

// MARK: - Bridging from Foundation objects (Yams / JSONSerialization output)

extension ConfigValue {
    public init(any: Any?) {
        guard let any else { self = .null; return }
        switch any {
        case is NSNull: self = .null
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let s as String: self = .string(s)
        case let a as [Any?]: self = .array(a.map { ConfigValue(any: $0) })
        case let a as [Any]: self = .array(a.map { ConfigValue(any: $0) })
        case let o as [String: Any?]: self = .object(o.mapValues { ConfigValue(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { ConfigValue(any: $0) })
        case let o as [AnyHashable: Any]:
            var r: [String: ConfigValue] = [:]
            for (k, v) in o { r[String(describing: k.base)] = ConfigValue(any: v) }
            self = .object(r)
        case let d as Date: self = .string(ISO8601DateFormatter().string(from: d))
        case let data as Data: self = .string(data.base64EncodedString())
        default: self = .string(String(describing: any))
        }
    }
}
