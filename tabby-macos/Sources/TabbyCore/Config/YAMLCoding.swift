import Foundation
import Yams

/// YAML reading and writing for `ConfigValue`.
///
/// Tabby writes its config with js-yaml (YAML 1.2 core schema), where `off`/`on`/`yes`/`no`
/// are plain strings. Yams defaults to YAML 1.1 booleans, so the loader narrows the boolean
/// rule to `true`/`false` to read Tabby files faithfully. When writing, strings that a
/// YAML 1.1 reader could misinterpret are single-quoted.
public enum YAMLCoding {
    static let resolver: Resolver = {
        (try? Resolver.default.replacing(.bool, with: "^(?:true|True|TRUE|false|False|FALSE)$")) ?? .default
    }()

    public static func parse(_ text: String) throws -> ConfigValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyObject }
        let any = try Yams.load(yaml: text, resolver)
        return ConfigValue(any: any)
    }

    public static func serialize(_ value: ConfigValue) throws -> String {
        try Yams.serialize(node: node(for: value), allowUnicode: true, sortKeys: true)
    }

    static func node(for value: ConfigValue) -> Node {
        switch value {
        case .null:
            return Node("null", Tag(.null))
        case .bool(let b):
            return Node(b ? "true" : "false", Tag(.bool))
        case .int(let i):
            return Node(String(i), Tag(.int))
        case .double(let d):
            let s: String
            if d.isNaN { s = ".nan" } else if d.isInfinite { s = d < 0 ? "-.inf" : ".inf" } else { s = String(d) }
            return Node(s, Tag(.float))
        case .string(let s):
            let scalar: Node.Scalar = s.represented()
            return .scalar(scalar)
        case .array(let a):
            return Node(a.map { node(for: $0) })
        case .object(let o):
            let pairs = o.keys.sorted().map { key -> (Node, Node) in
                let keyScalar: Node.Scalar = key.represented()
                return (.scalar(keyScalar), node(for: o[key]!))
            }
            return Node(pairs)
        }
    }
}
