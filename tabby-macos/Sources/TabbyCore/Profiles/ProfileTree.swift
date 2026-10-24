import Foundation

/// A group of the profile tree (Tabby's `PartialProfileGroup` with its `children` and
/// `profiles`). `group == nil` is "Ungrouped"; built-in profiles get synthetic, non-editable
/// groups named after their provider's group.
public struct ProfileTreeNode: Identifiable, Hashable, Sendable {
    public var group: ProfileGroup?
    public var children: [ProfileTreeNode]
    public var profiles: [Profile]

    public init(group: ProfileGroup?, children: [ProfileTreeNode] = [], profiles: [Profile] = []) {
        self.group = group
        self.children = children
        self.profiles = profiles
    }

    public var id: String { group?.id ?? "" }
    /// The group's name; "Ungrouped" (translated) for profiles without a group.
    public var name: String { group?.name ?? L("Ungrouped") }
    /// This node's profiles and every descendant's.
    public var profileCount: Int { profiles.count + children.reduce(0) { $0 + $1.profileCount } }

    public static let builtinGroupPrefix = "builtin:"
}

extension ProfileRegistry {
    /// The groups nested by `parentGroupId`, holding `profiles` (in the order given): user
    /// groups by name, then "Ungrouped", then the built-in groups. A group whose parent is
    /// missing, or whose parents loop, is a root, so every group and profile shows once.
    public func tree(_ profiles: [Profile]) -> [ProfileTreeNode] {
        let groups = self.groups
        let byId = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parents = Dictionary(groups.map { ($0.id, effectiveParent(of: $0, byId: byId)) }, uniquingKeysWith: { a, _ in a })
        func parent(_ id: String) -> String? { parents[id] ?? nil }
        var members: [String: [Profile]] = [:]
        var ungrouped: [Profile] = []
        var builtinOrder: [String] = []
        var builtin: [String: [Profile]] = [:]
        for p in profiles {
            if p.isBuiltin {
                let name = p.group ?? L("Built-in")
                if builtin[name] == nil { builtinOrder.append(name) }
                builtin[name, default: []].append(p)
            } else if let g = p.group, byId[g] != nil {
                members[g, default: []].append(p)
            } else {
                ungrouped.append(p)
            }
        }
        func byName(_ a: ProfileGroup, _ b: ProfileGroup) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func node(_ g: ProfileGroup) -> ProfileTreeNode {
            let kids = groups.filter { parent($0.id) == g.id }.sorted(by: byName).map(node)
            return ProfileTreeNode(group: g, children: kids, profiles: members[g.id] ?? [])
        }
        var roots = groups.filter { parent($0.id) == nil }.sorted(by: byName).map(node)
        if !ungrouped.isEmpty { roots.append(ProfileTreeNode(group: nil, profiles: ungrouped)) }
        for name in builtinOrder {
            let g = ProfileGroup(id: ProfileTreeNode.builtinGroupPrefix + name, name: name, editable: false)
            roots.append(ProfileTreeNode(group: g, profiles: builtin[name] ?? []))
        }
        return roots
    }

    /// The parent a group hangs under in the tree: nil when it has none, when the parent is
    /// missing, or when following the parents leads back to the group itself.
    private func effectiveParent(of group: ProfileGroup, byId: [String: ProfileGroup]) -> String? {
        guard let parentId = group.parentGroupId, byId[parentId] != nil else { return nil }
        var seen: Set<String> = [group.id]
        var current: String? = parentId
        while let id = current {
            if id == group.id { return nil }
            if seen.contains(id) { break } // a loop above, not through this group
            seen.insert(id)
            current = byId[id]?.parentGroupId
            if let next = current, byId[next] == nil { break }
        }
        return parentId
    }

    /// Every group below `groupId`, however deep (a loop stops at the first repeat).
    public func descendants(of groupId: String) -> Set<String> {
        let groups = self.groups
        var result = Set<String>()
        var stack = [groupId]
        while let current = stack.popLast() {
            for g in groups where g.parentGroupId == current && g.id != groupId && !result.contains(g.id) {
                result.insert(g.id)
                stack.append(g.id)
            }
        }
        return result
    }

    /// The groups a group may move under: all but itself and its descendants (Tabby's
    /// `getValidParents`).
    public func validParents(for groupId: String) -> [ProfileGroup] {
        let excluded = descendants(of: groupId).union([groupId])
        return groups.filter { !excluded.contains($0.id) }
    }
}
