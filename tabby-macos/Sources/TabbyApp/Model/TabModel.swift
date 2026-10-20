#if canImport(AppKit)
import Foundation
import Observation
import TabbyCore
import TabbyTerminal

/// A top-level tab: a split layout of terminal panes. Every tab is a split container, as in
/// Tabby (`SplitTabComponent`).
@MainActor
@Observable
public final class TabModel: Identifiable {
    public let id = UUID()
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
        layout = SplitLayout(single: pane.id)
        panes[pane.id] = pane
        focusedPaneID = pane.id
    }

    public init(layout: SplitLayout, panes: [UUID: TerminalPane]) {
        self.layout = layout
        self.panes = panes
        focusedPaneID = layout.panes.first
    }

    public var orderedPanes: [TerminalPane] { layout.panes.compactMap { panes[$0] } }

    public var focusedPane: TerminalPane? {
        focusedPaneID.flatMap { panes[$0] } ?? orderedPanes.first
    }

    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        return focusedPane?.title ?? "Terminal"
    }

    public var progress: Double? {
        orderedPanes.compactMap(\.progress).max()
    }

    public var hasActivity: Bool {
        orderedPanes.contains { $0.hasActivity }
    }

    public var icon: String? { focusedPane?.profile.icon }

    // MARK: Layout changes

    public func insert(_ pane: TerminalPane, relativeTo: UUID?, side: SplitDirection) {
        panes[pane.id] = pane
        layout.insert(pane.id, relativeTo: relativeTo, side: side)
        maximizedPaneID = nil
        focusedPaneID = pane.id
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

    public var isEmpty: Bool { panes.isEmpty }

    public func resizeFocused(_ orientation: SplitOrientation, by step: Double) {
        guard let id = focusedPaneID else { return }
        layout.resize(id, orientation: orientation, by: step)
    }

    public func moveDivider(_ divider: SplitLayout.Divider, to fraction: Double) {
        layout.moveDivider(containerPath: divider.containerPath, index: divider.index, to: fraction)
    }

    public func equalize() { layout.equalize() }

    // MARK: Recovery

    public func recoveryToken(includeBuffer: Bool = true) -> RecoveryToken? {
        RecoveryToken.from(layout: layout, pinned: isPinned, customTitle: customTitle, color: color) { id in
            panes[id]?.recoveryState(includeBuffer: includeBuffer)
        }
    }
}
#endif
