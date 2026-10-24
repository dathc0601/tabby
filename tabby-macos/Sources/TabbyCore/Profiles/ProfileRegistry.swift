import Foundation

/// Profile bookkeeping on top of `ConfigStore`. Port of the parts of Tabby's
/// `ProfilesService` (`tabby-core/src/services/profiles.service.ts`) that don't open tabs.
public final class ProfileRegistry {
    public let config: ConfigStore
    public private(set) var providers: [ProfileProvider]
    public let recents: RecentProfilesStore

    /// Base defaults for every profile (`ProfilesService.profileDefaults`).
    public static let baseDefaults: ConfigValue = [
        "id": "", "type": "", "name": "", "group": "", "options": [:], "icon": "", "color": "",
        "disableDynamicTitle": false, "weight": 0, "isBuiltin": false, "isTemplate": false,
        "terminalColorScheme": nil, "behaviorOnSessionEnd": "auto",
    ]

    public init(config: ConfigStore, providers: [ProfileProvider], recents: RecentProfilesStore) {
        self.config = config
        self.providers = providers
        self.recents = recents
    }

    public func register(_ provider: ProfileProvider) {
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
    }

    public func provider(for type: String) -> ProfileProvider? {
        providers.first { $0.id == type }
    }

    // MARK: Listing

    public var userProfiles: [Profile] {
        (config.value("profiles")?.arrayValue ?? []).map(Profile.init(config:))
    }

    public var groups: [ProfileGroup] {
        (config.value("groups")?.arrayValue ?? []).map(ProfileGroup.init(config:))
    }

    public func builtinProfiles() -> [Profile] {
        providers.flatMap { $0.builtinProfiles() }
    }

    /// User profiles followed by built-ins, sorted by group then name, built-ins last.
    public func allProfiles(includeBuiltin: Bool = true, includeHidden: Bool = false) -> [Profile] {
        let blacklist = Set(config.value("profileBlacklist")?.stringArrayValue ?? [])
        let providerBlacklist = Set(config.value("providerBlacklist")?.stringArrayValue ?? [])
        var list = userProfiles
        if includeBuiltin { list += builtinProfiles() }
        list = list.filter { p in
            !providerBlacklist.contains(p.type) &&
                (includeHidden || (!blacklist.contains(p.id) && p.extra["hidden"]?.boolValue != true))
        }
        let groupNames = Dictionary(groups.map { ($0.id, groupPath($0.id)) }, uniquingKeysWith: { a, _ in a })
        return list.enumerated().sorted { l, r in
            let a = l.element, b = r.element
            if a.isBuiltin != b.isBuiltin { return !a.isBuiltin }
            let ga = a.group.map { groupNames[$0] ?? $0 } ?? ""
            let gb = b.group.map { groupNames[$0] ?? $0 } ?? ""
            if ga != gb { return ga.localizedCaseInsensitiveCompare(gb) == .orderedAscending }
            if a.weight != b.weight { return a.weight < b.weight }
            if a.isBuiltin { return l.offset < r.offset }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.map(\.element)
    }

    public func profile(withId id: String) -> Profile? {
        allProfiles(includeHidden: true).first { $0.id == id }
    }

    /// Group path such as `Work › Servers` (Tabby joins with "🡒", which macOS's menu and
    /// selector fonts can't draw).
    public func groupPath(_ groupId: String?) -> String {
        guard let groupId, !groupId.isEmpty else { return "" }
        var names: [String] = []
        var seen = Set<String>()
        var current: String? = groupId
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        while let id = current, !seen.contains(id) {
            seen.insert(id)
            guard let g = byId[id] else {
                names.insert(id, at: 0)
                break
            }
            names.insert(g.name, at: 0)
            current = g.parentGroupId
        }
        return names.joined(separator: " › ")
    }

    // MARK: Effective settings

    /// Applies the defaults layers: base → provider → `profileDefaults[type]` → group chain
    /// `defaults[type]` (outermost first) → the profile itself.
    public func resolved(_ profile: Profile) -> Profile {
        var layered = Self.baseDefaults
        if let p = provider(for: profile.type) {
            layered = layered.merged(with: p.configDefaults)
        }
        if let typeDefaults = config.value("profileDefaults")?[profile.type] {
            layered = layered.merged(with: typeDefaults)
        }
        for g in groupChain(profile.group).reversed() {
            if let d = g.defaults[profile.type] {
                layered = layered.merged(with: d)
            }
        }
        layered = layered.merged(with: profile.configValue).strippingMarkers()
        var result = Profile(config: layered)
        result.isBuiltin = profile.isBuiltin
        if result.name.isEmpty, let suggested = provider(for: profile.type)?.suggestedName(for: result) {
            result.name = suggested
        }
        return result
    }

    private func groupChain(_ groupId: String?) -> [ProfileGroup] {
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var chain: [ProfileGroup] = []
        var seen = Set<String>()
        var current = groupId
        while let id = current, let g = byId[id], !seen.contains(id) {
            seen.insert(id)
            chain.append(g)
            current = g.parentGroupId
        }
        return chain
    }

    // MARK: Editing

    /// Inserts or replaces a user profile, assigning an id when it has none.
    @discardableResult
    public func save(_ profile: Profile) -> Profile {
        var p = profile
        if p.id.isEmpty || p.isBuiltin {
            p.id = Profile.makeId(type: p.type, name: p.name)
            p.isBuiltin = false
        }
        var list = config.value("profiles")?.arrayValue ?? []
        if let index = list.firstIndex(where: { $0["id"]?.stringValue == p.id }) {
            list[index] = p.configValue
        } else {
            list.append(p.configValue)
        }
        config.set("profiles", .array(list))
        return p
    }

    /// Deletes a user profile and its "New tab" hotkey (Tabby's `deleteProfile`).
    public func delete(profileId: String) {
        let removed = (config.value("profiles")?.arrayValue ?? []).first { $0["id"]?.stringValue == profileId }
        let list = (config.value("profiles")?.arrayValue ?? []).filter { $0["id"]?.stringValue != profileId }
        config.set("profiles", .array(list))
        if let removed {
            let name = Profile(config: removed).hotkeyName
            if config.value(at: ["hotkeys", "profile", name]) != nil { config.set(at: ["hotkeys", "profile", name], nil) }
        }
    }

    public func save(_ group: ProfileGroup) {
        var list = config.value("groups")?.arrayValue ?? []
        if let index = list.firstIndex(where: { $0["id"]?.stringValue == group.id }) {
            list[index] = group.configValue
        } else {
            list.append(group.configValue)
        }
        config.set("groups", .array(list))
    }

    /// Deletes a group; its profiles move to the top level (or are deleted if asked), its
    /// subgroups move up to its parent, and its selector hotkey goes (Tabby's
    /// `deleteProfileGroup`).
    public func delete(groupId: String, deleteProfiles: Bool = false) {
        let all = config.value("groups")?.arrayValue ?? []
        let parent = all.first { $0["id"]?.stringValue == groupId }?["parentGroupId"]?.stringValue
        var groupsList = all.filter { $0["id"]?.stringValue != groupId }
        for i in groupsList.indices where groupsList[i]["parentGroupId"]?.stringValue == groupId {
            groupsList[i]["parentGroupId"] = parent.map(ConfigValue.string)
        }
        config.set("groups", .array(groupsList))
        if config.value(at: ["hotkeys", "group-selectors", groupId]) != nil {
            config.set(at: ["hotkeys", "group-selectors", groupId], nil)
        }
        var profiles = config.value("profiles")?.arrayValue ?? []
        if deleteProfiles {
            for removed in profiles where removed["group"]?.stringValue == groupId {
                let name = Profile(config: removed).hotkeyName
                if config.value(at: ["hotkeys", "profile", name]) != nil { config.set(at: ["hotkeys", "profile", name], nil) }
            }
            profiles.removeAll { $0["group"]?.stringValue == groupId }
        } else {
            for i in profiles.indices where profiles[i]["group"]?.stringValue == groupId {
                profiles[i]["group"] = nil
            }
        }
        config.set("profiles", .array(profiles))
    }

    // MARK: Hiding (Tabby's profileBlacklist)

    /// Whether the profile is hidden from selectors and menus: in `profileBlacklist`, or
    /// marked `hidden` by an earlier TabbyMac build.
    public func isHidden(_ profile: Profile) -> Bool {
        (config.value("profileBlacklist")?.stringArrayValue ?? []).contains(profile.id) || profile.extra["hidden"]?.boolValue == true
    }

    /// Hides or shows a profile through `profileBlacklist` (built-in profiles too).
    public func setHidden(_ profile: Profile, _ hidden: Bool) {
        var list = (config.value("profileBlacklist")?.stringArrayValue ?? []).filter { $0 != profile.id }
        if hidden { list.append(profile.id) }
        config.set("profileBlacklist", .array(list.map(ConfigValue.string)))
        if !hidden, profile.extra["hidden"] != nil, !profile.isBuiltin {
            var copy = profile
            copy.extra["hidden"] = nil
            save(copy)
        }
    }

    /// Moves the `hidden: true` flag of earlier TabbyMac builds into `profileBlacklist`.
    public func migrateLegacyHidden() {
        var profiles = config.value("profiles")?.arrayValue ?? []
        var blacklist = config.value("profileBlacklist")?.stringArrayValue ?? []
        var changed = false
        for i in profiles.indices where profiles[i]["hidden"] != nil {
            if profiles[i]["hidden"]?.boolValue == true, let id = profiles[i]["id"]?.stringValue, !blacklist.contains(id) {
                blacklist.append(id)
            }
            profiles[i]["hidden"] = nil
            changed = true
        }
        guard changed else { return }
        config.set("profiles", .array(profiles))
        config.set("profileBlacklist", .array(blacklist.map(ConfigValue.string)))
    }

    // MARK: Type defaults (Tabby's profileDefaults)

    /// `profileDefaults.<type>`: what every profile of the type starts from.
    public func typeDefaults(_ type: String) -> ConfigValue {
        config.value(at: ["profileDefaults", type]) ?? .emptyObject
    }

    /// Replaces a type's defaults; nil (or an empty object) removes them.
    public func setTypeDefaults(_ type: String, _ value: ConfigValue?) {
        let empty = value?.objectValue?.isEmpty ?? true
        config.set(at: ["profileDefaults", type], empty ? nil : value)
    }

    // MARK: Quick connect

    public func quickConnect(_ query: String, providerId: String? = nil) -> Profile? {
        let pid = providerId ?? config.string("defaultQuickConnectProvider") ?? "ssh"
        guard let provider = provider(for: pid), provider.supportsQuickConnect else { return nil }
        return provider.quickConnect(query)
    }

    // MARK: Selector

    public struct SelectorEntry: Hashable {
        public enum Kind: Hashable {
            case profile(Profile)
            case manageProfiles
            case clearRecent
            case quickConnect(providerId: String, query: String)
        }
        public var kind: Kind
        public var title: String
        public var group: String
        public var description: String
        public var icon: String?
        public var color: String?
        public var isRecent: Bool
    }

    /// Profile selector entries in Tabby's order: recent, user + built-in profiles, the
    /// "Manage profiles" item, and quick-connect entries for the current query.
    /// With `type` or `groupId` (Tabby's `profile-selectors.<type>` and
    /// `group-selectors.<id>` hotkeys) only those profiles are listed: no recent or built-in
    /// entries, and a group includes its subgroups.
    public func selectorEntries(query: String = "", type: String? = nil, groupId: String? = nil) -> [SelectorEntry] {
        var entries: [SelectorEntry] = []
        let filtered = type != nil || groupId != nil
        let recentLimit = filtered ? 0 : (config.int("terminal.showRecentProfiles") ?? 3)
        let recent = Array(recents.load().prefix(max(0, recentLimit)))
        for p in recent {
            entries.append(SelectorEntry(kind: .profile(p), title: p.name, group: L("Recent"),
                                         description: provider(for: p.type)?.description(for: p) ?? "",
                                         icon: p.icon, color: p.color, isRecent: true))
        }
        if !recent.isEmpty {
            entries.append(SelectorEntry(kind: .clearRecent, title: L("Clear recent profiles"), group: L("Recent"),
                                         description: "", icon: "trash", color: nil, isRecent: true))
        }
        // Tabby's type selector lists the type's built-ins whatever showBuiltinProfiles says;
        // a group has only user profiles.
        let showBuiltin = type != nil ? groupId == nil : (!filtered && (config.value("terminal.showBuiltinProfiles")?.boolValue ?? true))
        let groups = groupId.map { descendants(of: $0).union([$0]) }
        for p in allProfiles(includeBuiltin: showBuiltin) where !p.isTemplate {
            if let type, p.type != type { continue }
            if let groups, !groups.contains(p.group ?? "") { continue }
            let group = p.isBuiltin ? "Built-in" : groupPath(p.group)
            entries.append(SelectorEntry(kind: .profile(p), title: p.name, group: group,
                                         description: provider(for: p.type)?.description(for: p) ?? "",
                                         icon: p.icon, color: p.color, isRecent: false))
        }
        if !filtered {
            entries.append(SelectorEntry(kind: .manageProfiles, title: L("Manage profiles"), group: "",
                                         description: "", icon: "gearshape", color: nil, isRecent: false))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Quick connect: every type in the full selector, the type's own in a type selector,
        // none in a group selector (Tabby).
        if !trimmed.isEmpty && groupId == nil {
            let defaultId = config.string("defaultQuickConnectProvider") ?? "ssh"
            for provider in providers.sorted(by: { ($0.id == defaultId ? 0 : 1) < ($1.id == defaultId ? 0 : 1) })
            where provider.supportsQuickConnect && (type == nil || provider.id == type) {
                entries.append(SelectorEntry(kind: .quickConnect(providerId: provider.id, query: trimmed),
                                             title: trimmed, group: L("Quick connect"),
                                             description: provider.name, icon: "bolt", color: nil, isRecent: false))
            }
        }
        return entries
    }
}

/// The last-used profiles, most recent first (Tabby keeps these in localStorage).
public final class RecentProfilesStore {
    public let url: URL?
    public var limit = 20
    private var memory: [Profile] = []

    public init(url: URL?) {
        self.url = url
    }

    public func load() -> [Profile] {
        guard let url else { return memory }
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(ConfigValue.self, from: data) else { return [] }
        return (value.arrayValue ?? []).map(Profile.init(config:))
    }

    public func push(_ profile: Profile) {
        var list = load().filter { $0.id != profile.id || profile.id.isEmpty }
        if !profile.id.isEmpty || !list.contains(profile) {
            list.insert(profile, at: 0)
        }
        list = Array(list.prefix(limit))
        persist(list)
    }

    public func clear() {
        persist([])
    }

    private func persist(_ list: [Profile]) {
        guard let url else { memory = list; return }
        let value = ConfigValue.array(list.map(\.configValue))
        if let data = try? JSONEncoder().encode(value) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
