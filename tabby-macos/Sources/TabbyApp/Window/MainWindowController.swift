#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbyTerminal

/// The terminal window: frameless title bar with the tab bar in it, tab bodies, start page.
/// Port of Tabby's `AppRootComponent` plus the Electron window setup in `app/lib/window.ts`.
@MainActor
final class TerminalWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, WindowModelUI {
    let model = WindowModel()
    let toasts = ToastCenter()
    private let root = WindowRootView()
    private var toastHost: NSHostingView<ToastOverlay>!
    private var tabBarHost: NSHostingView<TabBarView>!
    private var startPageHost: NSHostingView<StartPageView>!
    /// A `SplitTreeView` per terminal tab, an `NSHostingView<ContentTabRoot>` per content tab.
    private var tabViews: [UUID: NSView] = [:]
    /// One view per pane for its whole life, so moving a pane between tabs keeps its buffer.
    private var paneContainers: [UUID: PaneContainerView] = [:]
    private var loops: [ObservationLoop] = []
    private var effectView: NSVisualEffectView?
    var onClose: ((MainWindowController) -> Void)?

    private var services: AppServices { .shared }

    init() {
        let window = TerminalWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = CGSize(width: 400, height: 300)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("TabbyMacMainWindow")
        super.init(window: window)
        window.delegate = self
        model.ui = self
        model.onRecoveryStateChanged = { RecoveryCoordinator.shared.scheduleSave() }

        let actions = TabBarActions(
            select: { [weak self] in self?.model.select($0.id) },
            close: { [weak self] in self?.requestCloseTab($0) },
            newTab: { [weak self] in _ = self?.runCommand("new-tab") },
            showProfiles: { [weak self] in _ = self?.runCommand("profile-selector") },
            showSettings: { [weak self] in self?.model.openSettings() },
            command: { [weak self] id, tab in
                guard let self else { return }
                if let tab { self.model.select(tab.id) }
                _ = self.runCommand(id)
            },
            move: { [weak self] id, index in self?.model.moveTab(id, to: index) },
            setColor: { tab, color in
                tab.color = color
                RecoveryCoordinator.shared.scheduleSave()
            }
        )
        tabBarHost = NSHostingView(rootView: TabBarView(model: model, actions: actions, placement: .top, leadingInset: 78))
        startPageHost = NSHostingView(rootView: StartPageView(
            newTab: { [weak self] in _ = self?.runCommand("new-tab") },
            showProfiles: { [weak self] in _ = self?.runCommand("profile-selector") },
            showSettings: { [weak self] in self?.model.openSettings() },
            openProfile: { [weak self] p in _ = self?.model.openTab(profile: p) }
        ))
        // The hosts sit under the transparent title bar of a full-size-content window. Without
        // this, SwiftUI insets their content by the title bar's safe area, so the tab bar grows
        // past `tabBarHeight` and paints over the terminal's first row.
        tabBarHost.safeAreaRegions = []
        startPageHost.safeAreaRegions = []
        toastHost = NSHostingView(rootView: ToastOverlay(center: toasts))
        toastHost.safeAreaRegions = []
        root.tabBar = tabBarHost
        root.startPage = startPageHost
        root.toasts = toastHost
        window.contentView = root
        root.addSubview(tabBarHost)
        root.addSubview(startPageHost)
        root.addSubview(toastHost)

        loops.append(ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = self.model.tabs.map(\.id)
            _ = self.model.activeTabID
        }, apply: { [weak self] in self?.syncTabViews() }))
        loops.append(ObservationLoop(track: {
            _ = AppServices.shared.theme.revision
            _ = AppServices.shared.configRevision
        }, apply: { [weak self] in self?.applyAppearance() }))
        loops.append(ObservationLoop(track: { [weak self] in
            _ = self?.toasts.toasts.count
        }, apply: { [weak self] in self?.root.needsLayout = true }))
        loops.append(ObservationLoop(track: { [weak self] in
            _ = self?.model.activeTab?.title
        }, apply: { [weak self] in
            self?.window?.title = self?.model.activeTab?.title ?? "TabbyMac"
            self?.layoutTrafficLights()
        }))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Appearance

    private var placement: TabBarPlacement {
        switch services.config.string("appearance.tabsLocation") {
        case "bottom": return .bottom
        case "left": return .left
        case "right": return .right
        default: return .top
        }
    }

    private func applyAppearance() {
        guard let window else { return }
        let theme = services.theme
        let config = services.config
        let frame = config.string("appearance.frame") ?? "thin"
        let fullscreen = window.styleMask.contains(.fullScreen)
        if frame == "native" {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
        } else {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
        window.title = model.activeTab?.title ?? "TabbyMac"
        window.backgroundColor = theme.vibrancy ? .clear : theme.chrome.windowBackground.nsColor
        window.isOpaque = !theme.vibrancy
        window.alphaValue = CGFloat(config.double("appearance.opacity") ?? 1)
        if theme.vibrancy {
            if effectView == nil {
                let v = NSVisualEffectView()
                v.material = .underWindowBackground
                v.blendingMode = .behindWindow
                v.state = .active
                root.addSubview(v, positioned: .below, relativeTo: nil)
                effectView = v
            }
        } else {
            effectView?.removeFromSuperview()
            effectView = nil
        }
        root.effectView = effectView
        // A docked window is the design's Quake panel: no traffic lights.
        let docked = (config.string("appearance.dock") ?? "off") != "off"
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = docked
        }
        let lights = frame != "native" && !fullscreen && !docked
        let inset: CGFloat = lights && (placement == .top || placement == .left) ? 78 : (docked ? 8 : 0)
        let place = placement
        let verticalInset: CGFloat = place.isVertical && lights ? 30 : 0
        tabBarHost.rootView = TabBarView(model: model, actions: tabBarHost.rootView.actions, placement: place,
                                         leadingInset: place.isVertical ? verticalInset : inset)
        root.placement = place
        root.tabBarHeight = CGFloat(theme.metrics.tabBar)
        root.hidesTabBar = fullscreen && !(config.value("appearance.tabsInFullscreen")?.boolValue ?? false)
        // With the tab bar anywhere but the top, keep the terminal clear of the transparent
        // title bar, which spans the whole window width even when the strip is on the left.
        root.contentTopInset = (frame != "native" && !fullscreen && place != .top) ? 28 : 0
        root.needsLayout = true
        layoutTrafficLights()
    }

    /// Centres the traffic lights in the tab bar (Tabby: `macOSWindowButtonsInsetX/Y`).
    private func layoutTrafficLights() {
        guard let window, window.titlebarAppearsTransparent, !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton), let container = close.superview?.superview else { return }
        let barHeight = placement == .top ? root.tabBarHeight : 30
        var f = container.frame
        f.size.height = barHeight
        f.origin.y = window.frame.height - barHeight
        container.frame = f
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = window.standardWindowButton(type) else { continue }
            b.setFrameOrigin(CGPoint(x: 14 + CGFloat(i) * 20, y: (barHeight - b.frame.height) / 2))
        }
    }

    // MARK: Tabs ↔ views

    private func syncTabViews() {
        for tab in model.tabs where tabViews[tab.id] == nil {
            let v: NSView
            if tab.content != nil {
                let host = NSHostingView(rootView: ContentTabRoot(tab: tab, close: { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.model.closeTab(tab.id)
                }))
                host.safeAreaRegions = []
                v = host
            } else {
                v = SplitTreeView(tab: tab, controller: self)
            }
            root.addSubview(v, positioned: .below, relativeTo: tabBarHost)
            tabViews[tab.id] = v
        }
        let live = Set(model.tabs.map(\.id))
        for (id, v) in tabViews where !live.contains(id) {
            v.removeFromSuperview()
            tabViews[id] = nil
        }
        let active = model.activeTab?.id
        for (id, v) in tabViews { v.isHidden = id != active }
        root.tabViews = tabViews
        root.activeTabID = active
        startPageHost.isHidden = !model.tabs.isEmpty
        root.needsLayout = true
        window?.title = model.activeTab?.title ?? "TabbyMac"
        layoutTrafficLights()
        prunePaneViews()
        if let pane = model.activePane {
            focusEngine(of: pane)
        } else if let tab = model.activeTab, tab.content != nil, let view = tabViews[tab.id] {
            // Keys must not keep going to the terminal of the tab that was active before.
            window?.makeFirstResponder(view)
        } else if model.tabs.isEmpty {
            window?.makeFirstResponder(startPageHost)
            startPageHost.rootView.focusRequest += 1
        }
    }

    /// The hosting view of a Settings or Welcome tab.
    func contentTabView(for tab: TabModel) -> NSView? {
        tab.content == nil ? nil : tabViews[tab.id]
    }

    func paneContainer(for pane: TerminalPane) -> PaneContainerView {
        if let v = paneContainers[pane.id] { return v }
        let v = PaneContainerView(pane: pane, controller: self)
        paneContainers[pane.id] = v
        return v
    }

    /// Drops views of panes that are no longer in any tab.
    func prunePaneViews() {
        let live = Set(model.tabs.flatMap { $0.panes.keys })
        for id in paneContainers.keys where !live.contains(id) {
            paneContainers[id]?.removeFromSuperview()
            paneContainers[id] = nil
        }
    }

    func paneView(for pane: TerminalPane) -> PaneContainerView? {
        if let tab = model.tabs.first(where: { $0.panes[pane.id] != nil }) {
            (tabViews[tab.id] as? SplitTreeView)?.syncPaneViews()
        }
        return paneContainers[pane.id]
    }

    private func focusEngine(of pane: TerminalPane) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Make sure a just-created pane view is in the hierarchy before focusing it.
                self.window?.contentView?.layoutSubtreeIfNeeded()
                guard let view = self.paneView(for: pane), view.window != nil, !view.isSearchVisible else { return }
                self.window?.makeFirstResponder(view.engine)
            }
        }
    }

    // MARK: WindowModelUI

    func confirmMultilinePaste(_ text: String, completion: @escaping (Bool) -> Void) {
        Prompts.confirmPaste(in: window, text: text, completion: completion)
    }

    func paneDidRequestFocus(_ pane: TerminalPane) {
        focusEngine(of: pane)
    }

    /// "Process completed": a toast when the pane's tab is in the background or another app is
    /// frontmost, and a system banner too in the latter case. Banners need an app bundle:
    /// `swift run` has none and xctest's main bundle is a tool, where posting raises.
    func notifyProcessEnded(_ pane: TerminalPane, code: Int32?) {
        notifyProcessEnded(pane, code: code, appIsActive: NSApp.isActive)
    }

    func notifyProcessEnded(_ pane: TerminalPane, code: Int32?, appIsActive: Bool) {
        let tab = model.tabs.first { $0.panes[pane.id] != nil }
        let inBackground = tab.map { $0 !== model.activeTab } ?? true
        if !appIsActive || inBackground {
            let ran = pane.startedAt.map { " · " + ToastCenter.duration(Date().timeIntervalSince($0)) } ?? ""
            let index = tab.flatMap { t in model.tabs.firstIndex { $0 === t } }.map { " " + L("in tab {number}", ["number": $0 + 1]) } ?? ""
            let what = code.map { L("{title} exited with code {code}", ["title": pane.title, "code": $0]) }
                ?? L("{title}: session ended", ["title": pane.title])
            toasts.show(ToastCenter.Toast(
                symbol: code == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                tint: code == 0 ? .success : .danger,
                title: L("Process completed"), detail: what + index + ran,
                actionTitle: L("Show"),
                action: { [weak self, weak pane] in
                    guard let self, let pane, self.model.tabs.contains(where: { $0.panes[pane.id] != nil }) else { return }
                    self.model.focus(paneID: pane.id)
                    self.window?.makeKeyAndOrderFront(nil)
                }))
        }
        guard !appIsActive else { return }
        Notifier.shared.post(title: pane.title,
                             body: code.map { L("Process exited with code {code}", ["code": $0]) } ?? L("Session ended"),
                             pane: pane.id)
    }

    /// "Notify when done" (Tabby: `new Notification('Process completed', { body: name })`).
    /// ★ The user asked for it, so the toast shows even when the pane is in view; the banner
    /// goes out too where macOS allows it.
    func notifyProcessCompleted(_ pane: TerminalPane, processName: String) {
        Notifier.shared.post(title: L("Process completed"), body: processName, pane: pane.id)
        toasts.show(ToastCenter.Toast(symbol: "checkmark.circle", tint: .success, title: L("Process completed"),
                                      detail: processName + whereIs(pane), actionTitle: L("Show"), action: focusAction(pane)))
    }

    /// "Notify on activity" (Tabby: `new Notification('Tab activity', { body: tab.title })`).
    func notifyActivity(_ pane: TerminalPane) {
        Notifier.shared.post(title: L("Tab activity"), body: pane.title, pane: pane.id)
        toasts.show(ToastCenter.Toast(symbol: "bell", tint: .accent, title: L("Tab activity"),
                                      detail: pane.title + whereIs(pane), actionTitle: L("Show"), action: focusAction(pane)))
    }

    /// Bounces the Dock icon once (Electron's `flashFrame` on macOS); tests replace it.
    static var requestAttention: () -> Void = { NSApp.requestUserAttention(.informationalRequest) }

    func paneRang(_ pane: TerminalPane) {
        paneRang(pane, appIsActive: NSApp.isActive)
    }

    /// Tabby: `if (config.terminal.bellFlashFrame) hostWindow.flashFrame()`, which Electron
    /// only does while the window is not focused.
    func paneRang(_ pane: TerminalPane, appIsActive: Bool) {
        guard services.terminalSettings.bellFlashFrame, !appIsActive else { return }
        Self.requestAttention()
    }

    /// " in tab 3", or nothing when the pane is gone.
    private func whereIs(_ pane: TerminalPane) -> String {
        model.tabs.firstIndex { $0.panes[pane.id] != nil }.map { " " + L("in tab {number}", ["number": $0 + 1]) } ?? ""
    }

    private func focusAction(_ pane: TerminalPane) -> () -> Void {
        { [weak pane] in if let pane { Notifier.shared.focus(paneID: pane.id) } }
    }

    func modelDidBecomeEmpty() {
        if services.config.bool("appearance.lastTabClosesWindow") {
            window?.close()
        }
    }

    // MARK: Closing

    /// Reasons to confirm before closing these panes: busy processes, open SSH connections.
    private func closeWarnings(_ panes: [TerminalPane]) -> String? {
        let sshWarn = services.config.bool("ssh.warnOnClose")
        return Self.closeMessage(panes.compactMap { $0.closeWarning(sshWarnOnClose: sshWarn) })
    }

    /// The warnings as one message, each once (two panes on one host ask once); nil when
    /// there are none.
    static func closeMessage(_ warnings: [String]) -> String? {
        var seen = Set<String>()
        let unique = warnings.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique.joined(separator: "\n")
    }

    /// ⌘W and the tab's Close. Pinned tabs ignore them, as in Tabby's `AppService.closeTab`.
    func requestCloseTab(_ tab: TabModel) {
        guard !tab.isPinned else { return }
        requestCloseTabs([tab])
    }

    /// Closes idle tabs at once and asks once before closing the busy ones.
    func requestCloseTabs(_ tabs: [TabModel]) {
        let busy = tabs.filter { closeWarnings($0.orderedPanes) != nil }
        for tab in tabs where !busy.contains(where: { $0 === tab }) { model.closeTab(tab.id) }
        guard let message = closeWarnings(busy.flatMap(\.orderedPanes)) else { return }
        Prompts.confirm(in: window, title: busy.count == 1 ? L("Close this tab?") : L("Close {busyCount} tabs?", ["busyCount": busy.count]),
                        message: message, confirm: L("Close"), destructive: true) { [weak self] ok in
            guard ok, let self else { return }
            for tab in busy { self.model.closeTab(tab.id) }
        }
    }

    func requestClosePane(_ pane: TerminalPane) {
        guard let message = closeWarnings([pane]) else {
            model.closePane(pane.id)
            return
        }
        Prompts.confirm(in: window, title: L("Close this pane?"), message: message, confirm: L("Close"),
                        destructive: true) { [weak self] ok in
            if ok { self?.model.closePane(pane.id) }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let message = closeWarnings(model.tabs.flatMap(\.orderedPanes)) else { return true }
        Prompts.confirm(in: window, title: L("Close this window?"), message: message,
                        confirm: L("Close"), destructive: true) { [weak self] ok in
            guard ok, let self else { return }
            self.closeAllTabsAndWindow()
        }
        return false
    }

    private func closeAllTabsAndWindow() {
        RecoveryCoordinator.shared.saveNow()
        for tab in model.tabs { model.closeTab(tab.id) }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        RecoveryCoordinator.shared.saveNow()
        for tab in model.tabs {
            for pane in tab.orderedPanes { pane.close() }
        }
        onClose?(self)
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }

    /// Dragging the free edge of a docked window sets its size for the next dock.
    func windowDidEndLiveResize(_ notification: Notification) {
        let config = services.config
        let side = config.string("appearance.dock") ?? "off"
        guard side != "off", let window, let area = window.screen?.visibleFrame, area.width > 0, area.height > 0 else { return }
        let fraction = side == "top" || side == "bottom" ? window.frame.height / area.height : window.frame.width / area.width
        config.set("appearance.dockFill", .double((min(max(Double(fraction), 0.2), 1) * 100).rounded() / 100))
    }
    func windowDidExitFullScreen(_ notification: Notification) { applyAppearance() }
    func windowDidEnterFullScreen(_ notification: Notification) { applyAppearance() }
    func windowDidBecomeKey(_ notification: Notification) {
        layoutTrafficLights()
        WindowManager.shared.lastActive = self
    }
}

/// Root content view: lays out the tab bar, tab bodies and start page.
@MainActor
final class WindowRootView: NSView {
    weak var tabBar: NSView?
    weak var startPage: NSView?
    weak var effectView: NSVisualEffectView?
    weak var toasts: NSView?
    var tabViews: [UUID: NSView] = [:]
    var activeTabID: UUID?
    var placement: TabBarPlacement = .top
    var tabBarHeight: CGFloat = 38
    var hidesTabBar = false
    var contentTopInset: CGFloat = 0

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        effectView?.frame = bounds
        var content = bounds
        if let tabBar {
            tabBar.isHidden = hidesTabBar
            if !hidesTabBar {
                switch placement {
                case .top:
                    tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight)
                    content = CGRect(x: 0, y: tabBarHeight, width: bounds.width, height: max(0, bounds.height - tabBarHeight))
                case .bottom:
                    tabBar.frame = CGRect(x: 0, y: bounds.height - tabBarHeight, width: bounds.width, height: tabBarHeight)
                    content = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - tabBarHeight))
                case .left:
                    tabBar.frame = CGRect(x: 0, y: 0, width: 200, height: bounds.height)
                    content = CGRect(x: 200, y: 0, width: max(0, bounds.width - 200), height: bounds.height)
                case .right:
                    tabBar.frame = CGRect(x: bounds.width - 200, y: 0, width: 200, height: bounds.height)
                    content = CGRect(x: 0, y: 0, width: max(0, bounds.width - 200), height: bounds.height)
                }
            }
        }
        if contentTopInset > 0 {
            content = CGRect(x: content.minX, y: content.minY + contentTopInset, width: content.width,
                             height: max(0, content.height - contentTopInset))
        }
        startPage?.frame = content
        for v in tabViews.values { v.frame = content }
        if let toasts {
            let size = toasts.fittingSize
            toasts.frame = CGRect(x: content.maxX - size.width, y: content.maxY - size.height, width: size.width, height: size.height)
        }
    }
}
#endif
