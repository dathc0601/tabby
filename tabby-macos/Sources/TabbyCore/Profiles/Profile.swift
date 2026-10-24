import Foundation

/// What to do when a session ends (`behaviorOnSessionEnd` in Tabby).
public enum SessionEndBehavior: String, CaseIterable, Codable, Sendable {
    case auto, keep, reconnect, close
}

/// A connection profile. Mirrors Tabby's `Profile` (`tabby-core/src/api/profileProvider.ts`).
///
/// `options` keeps the provider-specific options as a raw tree so unknown fields survive;
/// typed views live in `LocalOptions` and `SSHOptions`.
public struct Profile: Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var name: String
    public var group: String?
    public var options: ConfigValue
    public var icon: String?
    public var color: String?
    public var disableDynamicTitle: Bool
    public var behaviorOnSessionEnd: SessionEndBehavior
    public var weight: Int
    public var isBuiltin: Bool
    public var isTemplate: Bool
    public var clearServiceMessagesOnConnect: Bool
    public var terminalColorScheme: ConfigValue?
    /// Any other top-level keys present in config.yaml.
    public var extra: [String: ConfigValue]

    public init(
        id: String = "",
        type: String,
        name: String,
        group: String? = nil,
        options: ConfigValue = .emptyObject,
        icon: String? = nil,
        color: String? = nil,
        disableDynamicTitle: Bool = false,
        behaviorOnSessionEnd: SessionEndBehavior = .auto,
        weight: Int = 0,
        isBuiltin: Bool = false,
        isTemplate: Bool = false,
        clearServiceMessagesOnConnect: Bool? = nil,
        terminalColorScheme: ConfigValue? = nil,
        extra: [String: ConfigValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.name = name
        self.group = group
        self.options = options
        self.icon = icon
        self.color = color
        self.disableDynamicTitle = disableDynamicTitle
        self.behaviorOnSessionEnd = behaviorOnSessionEnd
        self.weight = weight
        self.isBuiltin = isBuiltin
        self.isTemplate = isTemplate
        self.clearServiceMessagesOnConnect = clearServiceMessagesOnConnect ?? Self.clearsServiceMessagesByDefault(type: type)
        self.terminalColorScheme = terminalColorScheme
        self.extra = extra
    }

    static let knownKeys: Set<String> = [
        "id", "type", "name", "group", "options", "icon", "color", "disableDynamicTitle",
        "behaviorOnSessionEnd", "weight", "isBuiltin", "isTemplate", "clearServiceMessagesOnConnect",
        "terminalColorScheme",
    ]

    /// Builds a profile from a (possibly partial) config.yaml entry.
    public init(config v: ConfigValue) {
        func str(_ k: String) -> String? {
            guard let s = v[k]?.stringValue, !s.isEmpty else { return nil }
            return s
        }
        self.init(
            id: str("id") ?? "",
            type: str("type") ?? "local",
            name: v["name"]?.stringValue ?? "",
            group: str("group"),
            options: v["options"] ?? .emptyObject,
            icon: str("icon"),
            color: str("color"),
            disableDynamicTitle: v["disableDynamicTitle"]?.boolValue ?? false,
            behaviorOnSessionEnd: v["behaviorOnSessionEnd"]?.stringValue.flatMap(SessionEndBehavior.init(rawValue:)) ?? .auto,
            weight: v["weight"]?.intValue ?? 0,
            isBuiltin: v["isBuiltin"]?.boolValue ?? false,
            isTemplate: v["isTemplate"]?.boolValue ?? false,
            clearServiceMessagesOnConnect: v["clearServiceMessagesOnConnect"]?.boolValue,
            terminalColorScheme: v["terminalColorScheme"].flatMap { $0.isNull ? nil : $0 },
            extra: (v.objectValue ?? [:]).filter { !Profile.knownKeys.contains($0.key) }
        )
    }

    /// The config.yaml form. Only non-default fields are written, like Tabby.
    public var configValue: ConfigValue {
        var o = extra
        o["id"] = .string(id)
        o["type"] = .string(type)
        o["name"] = .string(name)
        if let group, !group.isEmpty { o["group"] = .string(group) }
        o["options"] = options
        if let icon, !icon.isEmpty { o["icon"] = .string(icon) }
        if let color, !color.isEmpty { o["color"] = .string(color) }
        if disableDynamicTitle { o["disableDynamicTitle"] = true }
        if behaviorOnSessionEnd != .auto { o["behaviorOnSessionEnd"] = .string(behaviorOnSessionEnd.rawValue) }
        if weight != 0 { o["weight"] = .int(weight) }
        if isTemplate { o["isTemplate"] = true }
        if clearServiceMessagesOnConnect != Self.clearsServiceMessagesByDefault(type: type) {
            o["clearServiceMessagesOnConnect"] = .bool(clearServiceMessagesOnConnect)
        }
        if let terminalColorScheme { o["terminalColorScheme"] = terminalColorScheme }
        return .object(o)
    }

    /// Whether a connection clears its service messages once connected when the profile
    /// doesn't say: Tabby's provider defaults (SSH yes; serial and telnet no).
    public static func clearsServiceMessagesByDefault(type: String) -> Bool { type == "ssh" }

    /// Tabby's id scheme for user profiles: `<type>:custom:<slug(name)>:<uuid>`.
    public static func makeId(type: String, name: String) -> String {
        "\(type):custom:\(Slug.make(name)):\(UUID().uuidString.lowercased())"
    }

    /// Tabby's `getProfileHotkeyName`: the id with `.` turned into `-` (a hotkey path segment).
    public var hotkeyName: String { (id.isEmpty ? name : id).replacingOccurrences(of: ".", with: "-") }

    /// The hotkey id Tabby uses to open this profile (`profile.<hotkeyName>`).
    public var hotkeyId: String { "profile." + hotkeyName }
}

/// A profile group. Groups nest through `parentGroupId` and can carry per-provider defaults.
public struct ProfileGroup: Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var parentGroupId: String?
    public var icon: String?
    public var color: String?
    public var defaults: [String: ConfigValue]
    public var editable: Bool
    public var extra: [String: ConfigValue]

    public init(id: String = UUID().uuidString.lowercased(), name: String, parentGroupId: String? = nil,
                icon: String? = nil, color: String? = nil, defaults: [String: ConfigValue] = [:],
                editable: Bool = true, extra: [String: ConfigValue] = [:]) {
        self.id = id
        self.name = name
        self.parentGroupId = parentGroupId
        self.icon = icon
        self.color = color
        self.defaults = defaults
        self.editable = editable
        self.extra = extra
    }

    public init(config v: ConfigValue) {
        let known: Set<String> = ["id", "name", "parentGroupId", "icon", "color", "defaults", "editable", "profiles"]
        self.init(
            id: v["id"]?.stringValue ?? UUID().uuidString.lowercased(),
            name: v["name"]?.stringValue ?? "",
            parentGroupId: v["parentGroupId"]?.stringValue,
            icon: v["icon"]?.stringValue,
            color: v["color"]?.stringValue,
            defaults: v["defaults"]?.objectValue ?? [:],
            editable: v["editable"]?.boolValue ?? true,
            extra: (v.objectValue ?? [:]).filter { !known.contains($0.key) }
        )
    }

    public var configValue: ConfigValue {
        var o = extra
        o["id"] = .string(id)
        o["name"] = .string(name)
        if let parentGroupId { o["parentGroupId"] = .string(parentGroupId) }
        if let icon { o["icon"] = .string(icon) }
        if let color { o["color"] = .string(color) }
        if !defaults.isEmpty { o["defaults"] = .object(defaults) }
        return .object(o)
    }
}
