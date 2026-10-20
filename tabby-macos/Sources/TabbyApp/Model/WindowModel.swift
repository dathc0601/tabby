#if canImport(AppKit)
import Foundation
import Observation
import TabbyCore
import TabbyTerminal

/// UI hooks the window model needs (implemented by `MainWindowController`).
@MainActor
public protocol WindowModelUI: AnyObject {
    func confirmMultilinePaste(_ text: String, completion: @escaping (Bool) -> Void)
    func paneDidRequestFocus(_ pane: TerminalPane)
    func notifyProcessEnded(_ pane: TerminalPane, code: Int32?)
    func modelDidBecomeEmpty()
}

/// Tabs of one window (Tabby's `AppService` for a window).
@MainActor
@Observable
public final class WindowModel {
    public private(set) var tabs: [TabModel] = []
    public private(set) var activeTabID: UUID?
    @ObservationIgnored public weak var ui: WindowModelUI?
    @ObservationIgnored public var onRecoveryStateChanged: (() -> Void)?
    @ObservationIgnored private var closedTabs: [RecoveryToken] = []
    @ObservationIgnored private var previousTabID: UUID?
    @ObservationIgnored private var mru: [UUID] = []

    private var services: AppServices { .shared }

    public init() {}

    public var activeTab: TabModel? {
        activeTabID.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first
    }

    public var activePane: TerminalPane? { activeTab?.focusedPane }

    // MARK: Creating panes

    /// Creates a pane for a profile (defaults applied), wired to this window.
    public func makePane(profile: Profile, cwd: String? = nil, restore: PaneRecovery? = nil) -> TerminalPane? {
        let resolved = services.profiles.resolved(profile)
        guard let factory = services.factory(for: resolved) else { return nil }
        let pane = TerminalPane(
            profile: resolved,
            factory: factory,
            context: services.sessionContext(cwd: cwd ?? restore?.cwd),
            settings: services.terminalSettings,
            scheme: services.theme.scheme(for: resolved),
            restore: restore
        )
        wire(pane)
        if !resolved.isTemplate && restore == nil {
            services.profiles.recents.push(profile)
        }
        return pane
    }

    private func wire(_ pane: TerminalPane) {
        pane.onRequestClose = { [weak self] p in
            MainActor.assumeIsolated { self?.closePane(p.id, force: true) }
        }
        pane.onFocus = { [weak self] p in
            MainActor.assumeIsolated { self?.focus(paneID: p.id) }
        }
        pane.onRequestPasteConfirmation = { [weak self] p, text in
            MainActor.assumeIsolated {
                self?.ui?.confirmMultilinePaste(text) { ok in
                    if ok { p.confirmPaste() } else { p.cancelPaste() }
                }
            }
        }
        pane.onProcessEnded = { [weak self] p, code in
            MainActor.assumeIsolated { self?.ui?.notifyProcessEnded(p, code: code) }
        }
        pane.onUserInput = { [weak self] p, data in
            MainActor.assumeIsolated {
                guard let tab = self?.tabs.first(where: { $0.panes[p.id] != nil }), tab.broadcastInput else { return }
                for other in tab.orderedPanes where other !== p { other.send(data) }
            }
        }
        pane.onRecoveryStateChanged = { [weak self] in
            MainActor.assumeIsolated { self?.onRecoveryStateChanged?() }
        }
    }

    // MARK: Tabs

    @discardableResult
    public func openTab(profile: Profile? = nil, cwd: String? = nil) -> TabModel? {
        let p = profile ?? services.defaultProfile()
        let inherited = cwd ?? (p.type == "local" ? activePane?.currentDirectory() : nil)
        guard let pane = makePane(profile: p, cwd: inherited) else { return nil }
        let tab = TabModel(pane: pane)
        insertTab(tab)
        return tab
    }

    public func insertTab(_ tab: TabModel, at index: Int? = nil) {
        let i = index ?? (activeTab.flatMap { t in tabs.firstIndex { $0 === t } }.map { $0 + 1 } ?? tabs.count)
        tabs.insert(tab, at: min(max(i, 0), tabs.count))
        select(tab.id)
        onRecoveryStateChanged?()
    }

    public func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        if activeTabID != id { previousTabID = activeTabID }
        activeTabID = id
        mru.removeAll { $0 == id }
        mru.insert(id, at: 0)
        for t in tabs {
            for p in t.orderedPanes { p.isFocused = t.id == id && t.focusedPaneID == p.id }
        }
        if let pane = activeTab?.focusedPane { ui?.paneDidRequestFocus(pane) }
    }

    public func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    public func selectRelative(_ delta: Int) {
        guard let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }), !tabs.isEmpty else { return }
        let cycle = services.config.value("appearance.cycleTabs")?.boolValue ?? true
        var next = i + delta
        if cycle {
            next = (next % tabs.count + tabs.count) % tabs.count
        } else {
            next = min(max(next, 0), tabs.count - 1)
        }
        select(tabs[next].id)
    }

    public func selectMRU(_ delta: Int) {
        guard mru.count > 1 else { return }
        let target = delta > 0 ? mru[1] : mru[mru.count - 1]
        select(target)
    }

    public func toggleLastTab() {
        if let prev = previousTabID { select(prev) }
    }

    public func moveActiveTab(by delta: Int) {
        guard let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }) else { return }
        let j = i + delta
        guard tabs.indices.contains(j) else { return }
        tabs.swapAt(i, j)
        onRecoveryStateChanged?()
    }

    public func moveTab(_ id: UUID, to index: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: i)
        tabs.insert(tab, at: min(max(index, 0), tabs.count))
        onRecoveryStateChanged?()
    }

    /// Closes a tab, remembering it for "Reopen last tab".
    public func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[i]
        if let token = tab.recoveryToken() {
            closedTabs.append(token)
            if closedTabs.count > 20 { closedTabs.removeFirst() }
        }
        for pane in tab.orderedPanes { pane.close() }
        tabs.remove(at: i)
        mru.removeAll { $0 == id }
        if activeTabID == id {
            let next = mru.first(where: { m in tabs.contains { $0.id == m } }) ?? (tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].id)
            activeTabID = nil
            if let next { select(next) }
        }
        onRecoveryStateChanged?()
        if tabs.isEmpty { ui?.modelDidBecomeEmpty() }
    }

    public func closeOtherTabs(_ id: UUID) {
        for t in tabs where t.id != id && !t.isPinned { closeTab(t.id) }
    }

    public func closeTabs(toThe side: SplitDirection, of id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let victims = side == .left ? Array(tabs[..<i]) : Array(tabs[(i + 1)...])
        for t in victims where !t.isPinned { closeTab(t.id) }
    }

    public func reopenLastTab() {
        guard let token = closedTabs.popLast() else { return }
        restore(token)
    }

    public func duplicateTab(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }), let token = tab.recoveryToken() else { return }
        restore(token, includeBuffer: false)
    }

    // MARK: Panes

    public func focus(paneID: UUID) {
        guard let tab = tabs.first(where: { $0.panes[paneID] != nil }) else { return }
        tab.focusedPaneID = paneID
        if tab.maximizedPaneID != nil && tab.maximizedPaneID != paneID { tab.maximizedPaneID = nil }
        if activeTabID != tab.id {
            select(tab.id)
        } else {
            for p in tab.orderedPanes { p.isFocused = p.id == paneID }
            if let pane = tab.panes[paneID] { ui?.paneDidRequestFocus(pane) }
        }
    }

    public func split(_ side: SplitDirection, profile: Profile? = nil) {
        guard let tab = activeTab else { openTab(profile: profile); return }
        let base = tab.focusedPane
        let p = profile ?? base.map { services.profiles.resolved($0.profile) } ?? services.defaultProfile()
        guard let pane = makePane(profile: p, cwd: base?.currentDirectory()) else { return }
        tab.insert(pane, relativeTo: base?.id, side: side)
        focus(paneID: pane.id)
        onRecoveryStateChanged?()
    }

    /// Closes a pane; closes the tab when it was the last one.
    public func closePane(_ paneID: UUID, force: Bool = false) {
        guard let tab = tabs.first(where: { $0.panes[paneID] != nil }) else { return }
        if tab.panes.count == 1 {
            closeTab(tab.id)
            return
        }
        tab.remove(paneID)?.close()
        if let next = tab.focusedPaneID { focus(paneID: next) }
        onRecoveryStateChanged?()
    }

    public func navigatePane(_ direction: SplitDirection) {
        guard let tab = activeTab, let id = tab.focusedPaneID else { return }
        focus(paneID: tab.layout.neighbour(of: id, direction: direction))
    }

    public func navigatePaneLinear(_ delta: Int) {
        guard let tab = activeTab, let id = tab.focusedPaneID else { return }
        focus(paneID: tab.layout.pane(after: id, delta: delta))
    }

    public func navigatePane(index: Int) {
        guard let tab = activeTab, tab.layout.panes.indices.contains(index) else { return }
        focus(paneID: tab.layout.panes[index])
    }

    public func toggleMaximize() {
        guard let tab = activeTab, let id = tab.focusedPaneID, tab.panes.count > 1 else { return }
        tab.maximizedPaneID = tab.maximizedPaneID == nil ? id : nil
    }

    public func resizePane(_ orientation: SplitOrientation, grow: Bool) {
        let step = services.config.double("terminal.paneResizeStep") ?? 0.1
        activeTab?.resizeFocused(orientation, by: grow ? step : -step)
        onRecoveryStateChanged?()
    }

    /// Turns every pane of the active tab into its own tab (`explode-tab`).
    public func explodeActiveTab() {
        guard let tab = activeTab, tab.panes.count > 1 else { return }
        for id in tab.layout.panes.dropFirst() {
            if let pane = tab.remove(id) {
                insertTab(TabModel(pane: pane))
            }
        }
    }

    /// Moves the panes of all other tabs into the active tab (`combine-tabs`).
    public func combineTabs() {
        guard let target = activeTab else { return }
        for tab in tabs where tab !== target {
            for id in tab.layout.panes {
                if let pane = tab.remove(id) { target.insert(pane, relativeTo: nil, side: .right) }
            }
        }
        tabs.removeAll { $0 !== target && $0.isEmpty }
        select(target.id)
        onRecoveryStateChanged?()
    }

    /// Restarts the active pane with another profile (`switch-profile`).
    public func switchActivePane(to profile: Profile) {
        guard let tab = activeTab, let old = tab.focusedPane,
              let pane = makePane(profile: profile, cwd: old.currentDirectory()) else { return }
        old.close()
        tab.replace(old.id, with: pane)
        focus(paneID: pane.id)
        onRecoveryStateChanged?()
    }

    // MARK: Recovery

    public func recoveryTokens(includeBuffers: Bool = true) -> [RecoveryToken] {
        tabs.compactMap { $0.recoveryToken(includeBuffer: includeBuffers) }
    }

    public func restore(_ token: RecoveryToken, includeBuffer: Bool = true) {
        let (layout, map) = token.makeLayout()
        var panes: [UUID: TerminalPane] = [:]
        var idMap: [UUID: UUID] = [:]
        for (id, state) in map {
            var s = state
            if !includeBuffer { s.savedState = nil }
            guard let pane = makePane(profile: s.profile, cwd: s.cwd, restore: s) else { continue }
            panes[pane.id] = pane
            idMap[id] = pane.id
        }
        guard !panes.isEmpty else { return }
        var newLayout = layout
        for (old, new) in idMap { newLayout.replace(old, with: new) }
        for id in newLayout.panes where idMap.values.contains(id) == false { newLayout.remove(id) }
        let tab = TabModel(layout: newLayout, panes: panes)
        if case let .split(_, _, _, pinned, title, color) = token {
            tab.isPinned = pinned
            tab.customTitle = title
            tab.color = color
        }
        insertTab(tab, at: tabs.count)
    }
}
#endif
