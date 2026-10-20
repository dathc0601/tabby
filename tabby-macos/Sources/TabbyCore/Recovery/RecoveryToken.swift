import Foundation

/// Saved state of one pane, compatible with Tabby's `app:local-tab` / `app:ssh-tab` tokens
/// (`tabby-local/src/recoveryProvider.ts`, `tabby-ssh/src/recoveryProvider.ts`).
public struct PaneRecovery: Hashable, Sendable {
    /// `app:local-tab`, `app:ssh-tab`, ...
    public var type: String
    public var profile: Profile
    public var cwd: String?
    /// Plain-text snapshot of the terminal buffer, replayed on restore.
    public var savedState: String?
    public var title: String?
    public var customTitle: String?
    public var color: String?
    public var disableDynamicTitle: Bool

    public init(type: String, profile: Profile, cwd: String? = nil, savedState: String? = nil,
                title: String? = nil, customTitle: String? = nil, color: String? = nil, disableDynamicTitle: Bool = false) {
        self.type = type
        self.profile = profile
        self.cwd = cwd
        self.savedState = savedState
        self.title = title
        self.customTitle = customTitle
        self.color = color
        self.disableDynamicTitle = disableDynamicTitle
    }

    public static func type(forProfileType t: String) -> String { "app:\(t)-tab" }
}

/// A tab's recovery token: a split container tree whose leaves are panes.
public indirect enum RecoveryToken: Hashable, Sendable {
    case split(orientation: SplitOrientation, ratios: [Double], children: [RecoveryToken], pinned: Bool, customTitle: String?, color: String?)
    case pane(PaneRecovery)

    public static let splitType = "app:split-tab"

    public init?(_ v: ConfigValue) {
        guard let type = v["type"]?.stringValue else { return nil }
        if type == Self.splitType {
            let children = (v["children"]?.arrayValue ?? []).compactMap(RecoveryToken.init)
            guard !children.isEmpty else { return nil }
            var ratios = (v["ratios"]?.arrayValue ?? []).compactMap(\.doubleValue)
            if ratios.count != children.count {
                ratios = Array(repeating: 1 / Double(children.count), count: children.count)
            }
            self = .split(
                orientation: SplitOrientation(rawValue: v["orientation"]?.stringValue ?? "h") ?? .horizontal,
                ratios: ratios,
                children: children,
                pinned: v["tabPinned"]?.boolValue ?? false,
                customTitle: v["tabCustomTitle"]?.stringValue,
                color: v["tabColor"]?.stringValue
            )
        } else {
            guard let profileValue = v["profile"] else { return nil }
            var profile = Profile(config: profileValue)
            if profile.type.isEmpty || profileValue["type"] == nil {
                profile.type = type.replacingOccurrences(of: "app:", with: "").replacingOccurrences(of: "-tab", with: "")
            }
            let cwd = v["cwd"]?.stringValue ?? profileValue.value(at: "options.cwd")?.stringValue
            self = .pane(PaneRecovery(
                type: type,
                profile: profile,
                cwd: cwd,
                savedState: v["savedState"]?.stringValue,
                title: v["tabTitle"]?.stringValue,
                customTitle: v["tabCustomTitle"]?.stringValue,
                color: v["tabColor"]?.stringValue,
                disableDynamicTitle: v["disableDynamicTitle"]?.boolValue ?? false
            ))
        }
    }

    public var configValue: ConfigValue {
        switch self {
        case let .split(orientation, ratios, children, pinned, customTitle, color):
            var o: [String: ConfigValue] = [
                "type": .string(Self.splitType),
                "orientation": .string(orientation.rawValue),
                "ratios": .array(ratios.map { .double($0) }),
                "children": .array(children.map(\.configValue)),
            ]
            if pinned { o["tabPinned"] = true }
            if let customTitle { o["tabCustomTitle"] = .string(customTitle) }
            if let color { o["tabColor"] = .string(color) }
            return .object(o)
        case .pane(let p):
            var o: [String: ConfigValue] = [
                "type": .string(p.type),
                "profile": p.profile.configValue,
            ]
            if let cwd = p.cwd { o["cwd"] = .string(cwd) }
            if let s = p.savedState { o["savedState"] = .string(s) }
            if let t = p.title { o["tabTitle"] = .string(t) }
            if let t = p.customTitle { o["tabCustomTitle"] = .string(t) }
            if let c = p.color { o["tabColor"] = .string(c) }
            if p.disableDynamicTitle { o["disableDynamicTitle"] = true }
            return .object(o)
        }
    }

    public var panes: [PaneRecovery] {
        switch self {
        case .pane(let p): return [p]
        case .split(_, _, let children, _, _, _): return children.flatMap(\.panes)
        }
    }

    /// Rebuilds the split layout, assigning fresh ids to panes. Returns the layout and the
    /// pane for each id.
    public func makeLayout() -> (SplitLayout, [UUID: PaneRecovery]) {
        var map: [UUID: PaneRecovery] = [:]
        func build(_ t: RecoveryToken) -> SplitNode {
            switch t {
            case .pane(let p):
                let id = UUID()
                map[id] = p
                return .leaf(id)
            case let .split(orientation, ratios, children, _, _, _):
                return .container(SplitContainer(orientation: orientation, children: children.map(build), ratios: ratios))
            }
        }
        switch build(self) {
        case .container(let c):
            return (SplitLayout(root: c), map)
        case .leaf(let id):
            return (SplitLayout(single: id), map)
        }
    }

    /// Builds a token from a layout and per-pane state.
    public static func from(layout: SplitLayout, pinned: Bool = false, customTitle: String? = nil, color: String? = nil,
                            pane: (UUID) -> PaneRecovery?) -> RecoveryToken? {
        func build(_ node: SplitNode) -> RecoveryToken? {
            switch node {
            case .leaf(let id): return pane(id).map(RecoveryToken.pane)
            case .container(let c):
                var kids: [RecoveryToken] = []
                var ratios: [Double] = []
                for (i, child) in c.children.enumerated() {
                    if let t = build(child) {
                        kids.append(t)
                        ratios.append(c.ratios[i])
                    }
                }
                guard !kids.isEmpty else { return nil }
                return .split(orientation: c.orientation, ratios: ratios, children: kids, pinned: false, customTitle: nil, color: nil)
            }
        }
        guard case let .split(o, r, k, _, _, _)? = build(.container(layout.root)) else { return nil }
        return .split(orientation: o, ratios: r, children: k, pinned: pinned, customTitle: customTitle, color: color)
    }
}

/// Persists open tabs (Tabby keeps these in `localStorage.tabsRecovery`).
public final class RecoveryStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [RecoveryToken] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ConfigValue.self, from: data) else { return [] }
        return (value.arrayValue ?? []).compactMap(RecoveryToken.init)
    }

    public func save(_ tokens: [RecoveryToken]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ConfigValue.array(tokens.map(\.configValue)))
        try data.write(to: url, options: .atomic)
    }
}
