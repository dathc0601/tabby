#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// The sidebar's width and collapsed groups, kept in the app's defaults (Tabby keeps them in
/// localStorage).
enum ProfileSidebar {
    static let widthKey = "profileSidebar.width"
    static let collapsedKey = "profileSidebar.collapsedGroups"
    static var defaults: UserDefaults = .standard

    static func width(stored: Double?) -> CGFloat { CGFloat(min(max(stored ?? 250, 150), 500)) }
    static var width: CGFloat { width(stored: defaults.object(forKey: widthKey) as? Double) }
    static func saveWidth(_ width: CGFloat) { defaults.set(Double(Self.width(stored: Double(width))), forKey: widthKey) }

    static func collapsed() -> Set<String> { Set(defaults.stringArray(forKey: collapsedKey) ?? []) }
    static func saveCollapsed(_ ids: Set<String>) { defaults.set(ids.sorted(), forKey: collapsedKey) }
}

/// Tabby's profile sidebar (`profileTree.component`): a filter and the tree of profiles;
/// a double click or the play button opens a tab.
struct ProfileTreeView: View {
    let topInset: CGFloat
    let open: (Profile) -> Void
    @State private var filter = ""
    @State private var collapsed = ProfileSidebar.collapsed()
    @State private var hovered: String?
    @Environment(\.chrome) private var chrome

    /// The profiles the sidebar lists: not hidden, not templates, matching the filter.
    static func visibleTree(filter: String, registry: ProfileRegistry) -> [ProfileTreeNode] {
        let profiles = FuzzyMatcher.filter(registry.allProfiles(), query: filter) { $0.name }.filter { !$0.isTemplate }
        return registry.tree(profiles)
    }

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let rows = ProfilesSettingsView.rows(Self.visibleTree(filter: filter, registry: services.profiles), collapsed: collapsed,
                                             dropEmpty: true)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
                TextField(L("Filter"), text: $filter).textFieldStyle(.plain)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(chrome.fill.color))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(rows) { row in
                        switch row {
                        case let .group(node, depth): groupRow(node, depth: depth)
                        case let .profile(p, depth): profileRow(p, depth: depth)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, topInset)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(chrome.surface.color)
    }

    private func groupRow(_ node: ProfileTreeNode, depth: Int) -> some View {
        let open = !collapsed.contains(node.id)
        return HStack(spacing: 6) {
            Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                .foregroundStyle(chrome.textFaint.color).frame(width: 12)
            Image(systemName: ProfileIcons.symbol(for: node.group?.icon ?? "far fa-folder")) // l10n-ignore: Font Awesome class
                .foregroundStyle((node.group?.color.flatMap(ProfileColors.rgb) ?? chrome.textMuted).color)
            Text(node.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(ChromeFont.caption)
        .padding(.leading, CGFloat(depth) * 14)
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture {
            if collapsed.contains(node.id) { collapsed.remove(node.id) } else { collapsed.insert(node.id) }
            ProfileSidebar.saveCollapsed(collapsed)
        }
    }

    private func profileRow(_ p: Profile, depth: Int) -> some View {
        let tint = p.color.flatMap(ProfileColors.rgb)
        return HStack(spacing: 6) {
            Image(systemName: ProfileIcons.symbol(for: p.icon ?? ProfileIcons.defaultIcon(forType: p.type)))
                .foregroundStyle((tint ?? chrome.textMuted).color).frame(width: 16)
            Text(p.name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if hovered == p.id {
                IconButton(symbol: "play.fill", help: L("Open in a new tab"), size: 20) { open(p) }
            }
        }
        .font(ChromeFont.caption)
        .padding(.leading, CGFloat(depth) * 14)
        .padding(.trailing, 4)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovered == p.id ? chrome.fill.color : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(p) }
        .onHover { hovered = $0 ? p.id : (hovered == p.id ? nil : hovered) }
        .help(p.name)
    }
}

/// The sidebar's resize handle: drag to change its width.
final class SidebarGrabber: NSView {
    var resized: (CGFloat) -> Void = { _ in }
    var finished: () -> Void = {}
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0
    var currentWidth: () -> CGFloat = { 250 }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = currentWidth()
    }

    override func mouseDragged(with event: NSEvent) {
        resized(ProfileSidebar.width(stored: Double(startWidth + event.locationInWindow.x - startX)))
    }

    override func mouseUp(with event: NSEvent) { finished() }
}
#endif
