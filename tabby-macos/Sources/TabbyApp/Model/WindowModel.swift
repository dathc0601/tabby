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
    /// "Notify when done" fired for `pane` (phase 5).
    func notifyProcessCompleted(_ pane: TerminalPane, processName: String)
    /// "Notify on activity" fired for `pane` (phase 5).
    func notifyActivity(_ pane: TerminalPane)
    /// The terminal bell rang in `pane` (phase 5: the Dock bounce).
    func paneRang(_ pane: TerminalPane)
    func modelDidBecomeEmpty()
    /// Asks which port and baud rate a serial profile without them should use (Tabby asks
    /// the rate in `getNewTabParameters`); the completion gets the profile with the answers.
    /// When the user cancels, it may never be called (or gets nil): nothing opens either way.
    func completeSerialProfile(_ profile: Profile, missing: [SerialProfileProvider.Parameter],
                               completion: @escaping (Profile?) -> Void)
}

public extension WindowModelUI {
    func notifyProcessCompleted(_ pane: TerminalPane, processName: String) {}
    func notifyActivity(_ pane: TerminalPane) {}
    func paneRang(_ pane: TerminalPane) {}
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
        pane.onProcessCompleted = { [weak self] p, name in
            MainActor.assumeIsolated { self?.ui?.notifyProcessCompleted(p, processName: name) }
        }
        pane.onBell = { [weak self] p in
            MainActor.assumeIsolated { self?.ui?.paneRang(p) }
        }
        pane.onActivityNotification = { [weak self] p in
            MainActor.assumeIsolated { self?.ui?.notifyActivity(p) }
        }
        pane.onUserInput = { [weak self] p, data in
            MainActor.assumeIsolated {
                guard let tab = self?.tabs.first(where: { $0.panes[p.id] != nil }), tab.broadcastInput else { return }
                for other in tab.orderedPanes where other !== p { other.send(data) }
            }
        }
        pane.onPaste = { [weak self] p, text in
            MainActor.assumeIsolated {
                guard let tab = self?.tabs.first(where: { $0.panes[p.id] != nil }), tab.broadcastInput else { return }
                for other in tab.orderedPanes where other !== p { other.sendPaste(text) }
            }
        }
        pane.onRecoveryStateChanged = { [weak self] in
            MainActor.assumeIsolated { self?.onRecoveryStateChanged?() }
        }
    }

    /// A serial profile with no port or baud rate opens once the user answered (never when
    /// restoring: the recovery token keeps the answers). Returns whether it asked.
    private func askForMissingParameters(_ profile: Profile, then open: @escaping (Profile) -> Void) -> Bool {
        guard !skipAsking, let ui else { return false }
        let missing = SerialProfileProvider.missingParameters(services.profiles.resolved(profile))
        guard !missing.isEmpty else { return false }
        ui.completeSerialProfile(profile, missing: missing) { [weak self] completed in
            guard let self, let completed else { return }
            MainActor.assumeIsolated {
                // Answers that still leave a gap open anyway; the session says what's missing.
                self.skipAsking = true
                defer { self.skipAsking = false }
                open(completed)
            }
        }
        return true
    }

    @ObservationIgnored private var skipAsking = false

    // MARK: Tabs

    @discardableResult
    public func openTab(profile: Profile? = nil, cwd: String? = nil) -> TabModel? {
        let p = profile ?? services.defaultProfile()
        if askForMissingParameters(p, then: { [weak self] done in self?.openTab(profile: done, cwd: cwd) }) { return nil }
        // A local tab opens where the active pane is, unless its profile names a directory
        // (Tabby's `LocalProfilesService.getNewTabParameters`).
        let ownDirectory = LocalOptions(p.options).cwd.map { !$0.isEmpty } ?? false
        let inherited = cwd ?? (p.type == "local" && !ownDirectory ? activePane?.currentDirectory() : nil)
        guard let pane = makePane(profile: p, cwd: inherited) else { return nil }
        let tab = TabModel(pane: pane)
        insertTab(tab)
        return tab
    }

    /// Focuses this window's Settings tab, opening it at the end when there is none (Tabby's
    /// `SettingsTabComponent` is a singleton too).
    func openSettings(section: SettingsSection? = nil) {
        let tab = tabs.first { $0.content == .settings } ?? {
            let t = TabModel(content: .settings)
            insertTab(t)
            return t
        }()
        if let section { tab.settingsNavigation?.section = section }
        select(tab.id)
    }

    /// The first-run Welcome tab (Tabby's `WelcomeTabComponent`).
    func openWelcome() {
        if let tab = tabs.first(where: { $0.content == .welcome }) {
            select(tab.id)
        } else {
            insertTab(TabModel(content: .welcome))
        }
    }

    /// Adds and selects a tab, at `index` or after the last tab (Tabby's `addTabRaw`).
    public func insertTab(_ tab: TabModel, at index: Int? = nil) {
        tabs.insert(tab, at: min(max(index ?? tabs.count, 0), tabs.count))
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

    /// Moves the active tab one place within its group, wrapping around when `cycleTabs` is on
    /// (Tabby's `moveSelectedTabLeft/Right`).
    public func moveActiveTab(by delta: Int) {
        guard let active = activeTab, let i = tabs.firstIndex(where: { $0 === active }), tabs.count > 1 else { return }
        let bounds = reorderBounds(of: active)
        if bounds.contains(i + delta) {
            tabs.swapAt(i, i + delta)
            onRecoveryStateChanged?()
        } else if services.config.value("appearance.cycleTabs")?.boolValue ?? true, bounds.count > 1 {
            moveTab(active.id, to: delta < 0 ? bounds.upperBound : bounds.lowerBound)
        }
    }

    /// Moves a tab, keeping it inside its group (pinned or not).
    public func moveTab(_ id: UUID, to index: Int) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        let bounds = reorderBounds(of: tabs[i])
        let tab = tabs.remove(at: i)
        tabs.insert(tab, at: min(max(index, bounds.lowerBound), bounds.upperBound))
        onRecoveryStateChanged?()
    }

    // MARK: Pinned tabs

    /// Pinned tabs stay together at the front (Tabby's `getTabReorderBounds`).
    private func reorderBounds(of tab: TabModel) -> ClosedRange<Int> {
        let pinned = tabs.filter(\.isPinned).count
        return tab.isPinned ? 0...max(pinned - 1, 0) : pinned...max(tabs.count - 1, 0)
    }

    /// Pinning moves a tab to the end of the pinned group, unpinning to the start of the rest.
    public func togglePinned(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isPinned.toggle()
        let pinned = tabs.filter(\.isPinned).count
        moveTab(id, to: tab.isPinned ? pinned - 1 : pinned)
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

    /// The tabs "Close other tabs" closes (pinned tabs stay).
    public func tabs(otherThan id: UUID) -> [TabModel] {
        tabs.filter { $0.id != id && !$0.isPinned }
    }

    /// The tabs "Close tabs to the left/right" closes (pinned tabs stay).
    public func tabs(toThe side: SplitDirection, of id: UUID) -> [TabModel] {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let victims = side == .left ? Array(tabs[..<i]) : Array(tabs[(i + 1)...])
        return victims.filter { !$0.isPinned }
    }

    /// Reopens the last closed tab right after the active one, as Tabby does.
    public func reopenLastTab() {
        guard let token = closedTabs.popLast() else { return }
        restore(token, at: activeTab.flatMap { t in tabs.firstIndex { $0 === t } }.map { $0 + 1 })
    }

    /// Opens a copy of a tab right after it.
    public func duplicateTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }), let token = tabs[i].recoveryToken() else { return }
        restore(token, includeBuffer: false, at: i + 1)
    }

    /// Drops tab `id` on pane `paneID` of another tab: the pane splits on `side` and the tab's
    /// panes move in with their sessions. Returns false when the drop makes no sense.
    @discardableResult
    public func dropTab(_ id: UUID, onto paneID: UUID, side: SplitDirection) -> Bool {
        guard let source = tabs.first(where: { $0.id == id }), source.content == nil, !source.panes.isEmpty,
              let target = tabs.first(where: { $0.panes[paneID] != nil }), target !== source else { return false }
        target.absorb(source, relativeTo: paneID, side: side)
        tabs.removeAll { $0 === source }
        mru.removeAll { $0 == id }
        if activeTabID == id { activeTabID = nil }
        select(target.id)
        if let focused = target.focusedPaneID { focus(paneID: focused) }
        onRecoveryStateChanged?()
        return true
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
        guard let tab = activeTab, tab.content == nil else { openTab(profile: profile); return }
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

    /// Turns every pane of the active tab but the first into its own tab, added at the end
    /// (`explode-tab`).
    /// A rearranging drop inside a split (Tabby's `onTabDropped`): the pane moves next to
    /// `relativeTo`, or to an outer edge when it is nil. Ends rearranging.
    @discardableResult
    public func movePane(_ paneID: UUID, relativeTo: UUID?, side: SplitDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.panes[paneID] != nil }) else { return false }
        tab.isRearranging = false
        guard tab.move(paneID, relativeTo: relativeTo, side: side) else { return false }
        focus(paneID: paneID)
        onRecoveryStateChanged?()
        return true
    }

    /// A pane label dropped on the tab bar: the pane becomes a tab of its own, after its tab.
    @discardableResult
    public func detachPane(_ paneID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.panes[paneID] != nil }), tabs[index].panes.count > 1 else { return false }
        let source = tabs[index]
        source.isRearranging = false
        guard let pane = source.remove(paneID) else { return false }
        insertTab(TabModel(pane: pane), at: index + 1)
        return true
    }

    public func explodeActiveTab() {
        if let tab = activeTab { explode(tab) }
    }

    private func explode(_ tab: TabModel) {
        for id in tab.layout.panes.dropFirst() {
            if let pane = tab.remove(id) {
                insertTab(TabModel(pane: pane), at: tabs.count)
            }
        }
    }

    /// Moves the panes of all other tabs into the active tab, laid out in a grid
    /// (`combine-tabs`, Tabby's `combineTabsInto`).
    public func combineTabs() {
        guard let target = activeTab, target.content == nil else { return }
        explode(target)
        let panes = tabs.filter { $0 !== target }.flatMap { tab in tab.layout.panes.compactMap { tab.remove($0) } }
        // Fill rows of `stride` panes: each pane goes right of the previous one, and every
        // `stride`-th starts a new row at the bottom.
        let stride = Int(Double(panes.count + 1).squareRoot().rounded(.up))
        var column = 1
        var previous: UUID?
        for pane in panes {
            target.insert(pane, relativeTo: column == 0 ? nil : previous, side: column == 0 ? .bottom : .right)
            previous = pane.id
            column = (column + 1) % stride
        }
        target.equalize()
        tabs.removeAll { $0 !== target && $0.isEmpty }
        mru.removeAll { id in !tabs.contains { $0.id == id } }
        select(target.id)
        onRecoveryStateChanged?()
    }

    /// Restarts the active pane with another profile (`switch-profile`).
    public func switchActivePane(to profile: Profile) {
        if askForMissingParameters(profile, then: { [weak self] done in self?.switchActivePane(to: done) }) { return }
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

    /// Recreates a tab from a token, at `index` or after the last tab.
    public func restore(_ token: RecoveryToken, includeBuffer: Bool = true, at index: Int? = nil) {
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
        insertTab(tab, at: index ?? tabs.count)
    }
}
#endif
