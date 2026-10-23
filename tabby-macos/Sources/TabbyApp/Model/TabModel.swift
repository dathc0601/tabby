#if canImport(AppKit)
import Foundation
import Observation
import TabbyCore
import TabbyTerminal

/// What a tab shows when it is not a terminal (the phase 2 design opens these as tabs, as
/// Tabby does).
public enum ContentTabKind: Hashable, Sendable {
    case settings
    case welcome

    public var title: String {
        switch self {
        case .settings: return L("Settings")
        case .welcome: return L("Welcome")
        }
    }

    public var symbol: String {
        switch self {
        case .settings: return "gearshape"
        case .welcome: return "hand.wave"
        }
    }
}

/// A top-level tab: a split layout of terminal panes. Every terminal tab is a split container,
/// as in Tabby (`SplitTabComponent`); Settings and Welcome are content tabs without panes.
@MainActor
@Observable
public final class TabModel: Identifiable {
    public let id = UUID()
    /// Non-nil for Settings and Welcome tabs, which have no panes.
    public let content: ContentTabKind?
    /// The page a Settings tab shows.
    @ObservationIgnored private(set) var settingsNavigation: SettingsNavigation?
    public private(set) var layout: SplitLayout
    public private(set) var panes: [UUID: TerminalPane] = [:]
    public var focusedPaneID: UUID?
    public var maximizedPaneID: UUID?
    public var customTitle: String?
    public var color: String?
    public var isPinned = false
    /// Broadcast input to every pane (`pane-focus-all`).
    public var broadcastInput = false

    public init(pane: TerminalPane) {
        content = nil
        layout = SplitLayout(single: pane.id)
        panes[pane.id] = pane
        focusedPaneID = pane.id
    }

    public init(layout: SplitLayout, panes: [UUID: TerminalPane]) {
        content = nil
        self.layout = layout
        self.panes = panes
        focusedPaneID = layout.panes.first
    }

    init(content: ContentTabKind) {
        self.content = content
        // A placeholder leaf with no pane behind it: `orderedPanes` stays empty.
        layout = SplitLayout(single: UUID())
        focusedPaneID = nil
        if content == .settings { settingsNavigation = SettingsNavigation() }
    }

    public var orderedPanes: [TerminalPane] { layout.panes.compactMap { panes[$0] } }

    public var focusedPane: TerminalPane? {
        focusedPaneID.flatMap { panes[$0] } ?? orderedPanes.first
    }

    public var title: String {
        if let content { return content.title }
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return focusedPane?.title ?? L("Terminal")
    }

    public var progress: Double? {
        orderedPanes.compactMap(\.progress).max()
    }

    public var hasActivity: Bool {
        orderedPanes.contains { $0.hasActivity }
    }

    /// The focused pane's profile icon, or its type's (design C1b).
    public var icon: String? {
        focusedPane.map { $0.profile.icon ?? ProfileIcons.defaultIcon(forType: $0.profile.type) }
    }

    // MARK: Layout changes

    public func insert(_ pane: TerminalPane, relativeTo: UUID?, side: SplitDirection) {
        panes[pane.id] = pane
        layout.insert(pane.id, relativeTo: relativeTo, side: side)
        maximizedPaneID = nil
        focusedPaneID = pane.id
    }

    /// Moves another tab's panes in beside `relativeTo`, keeping their layout.
    func absorb(_ other: TabModel, relativeTo: UUID, side: SplitDirection) {
        let moved = other.layout.panes.compactMap { id in other.panes[id].map { (id, $0) } }
        guard !moved.isEmpty else { return }
        let subtree: SplitNode = moved.count == 1 ? .leaf(moved[0].0) : .container(other.layout.root)
        for (id, pane) in moved {
            other.panes[id] = nil
            panes[id] = pane
        }
        layout.insert(subtree, relativeTo: relativeTo, side: side)
        maximizedPaneID = nil
        focusedPaneID = other.focusedPaneID.flatMap { panes[$0] != nil ? $0 : nil } ?? moved[0].0
    }

    /// Removes a pane and returns it. The tab is empty afterwards when it was the last one.
    @discardableResult
    public func remove(_ paneID: UUID) -> TerminalPane? {
        guard let pane = panes.removeValue(forKey: paneID) else { return nil }
        let next = layout.remove(paneID)
        if maximizedPaneID == paneID { maximizedPaneID = nil }
        if focusedPaneID == paneID { focusedPaneID = next }
        return pane
    }

    public func replace(_ paneID: UUID, with pane: TerminalPane) {
        panes[paneID] = nil
        panes[pane.id] = pane
        layout.replace(paneID, with: pane.id)
        if focusedPaneID == paneID { focusedPaneID = pane.id }
    }

    /// A terminal tab whose last pane is gone. Content tabs are never empty.
    public var isEmpty: Bool { content == nil && panes.isEmpty }

    public func resizeFocused(_ orientation: SplitOrientation, by step: Double) {
        guard let id = focusedPaneID else { return }
        layout.resize(id, orientation: orientation, by: step)
    }

    public func moveDivider(_ divider: SplitLayout.Divider, to fraction: Double) {
        layout.moveDivider(containerPath: divider.containerPath, index: divider.index, to: fraction)
    }

    public func equalize() { layout.equalize() }

    // MARK: Recovery

    /// Content tabs are not saved, as in Tabby, which has no recovery provider for them.
    public func recoveryToken(includeBuffer: Bool = true) -> RecoveryToken? {
        guard content == nil else { return nil }
        return RecoveryToken.from(layout: layout, pinned: isPinned, customTitle: customTitle, color: color) { id in
            panes[id]?.recoveryState(includeBuffer: includeBuffer)
        }
    }
}
#endif
