#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbyTerminal

/// Lays out a tab's panes from its `SplitLayout` (Tabby's `SplitTabComponent` view) and
/// lets the user drag the dividers between them.
@MainActor
final class SplitTreeView: NSView {
    let tab: TabModel
    private weak var controller: MainWindowController?
    private var paneViews: [UUID: PaneContainerView] = [:]
    private var dividerViews: [DividerView] = []
    private var loop: ObservationLoop?
    static let spacing: CGFloat = 1

    init(tab: TabModel, controller: MainWindowController) {
        self.tab = tab
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        loop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            // Read what the layout depends on so changes trigger a relayout.
            _ = self.tab.layout
            _ = self.tab.panes.count
            _ = self.tab.maximizedPaneID
            _ = self.tab.focusedPaneID
            _ = AppServices.shared.theme.revision
        }, apply: { [weak self] in
            self?.needsLayout = true
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func paneView(for id: UUID) -> PaneContainerView? { paneViews[id] }

    override func layout() {
        super.layout()
        syncPaneViews()
        let multiple = tab.panes.count > 1
        let frames: [UUID: CGRect]
        if let max = tab.maximizedPaneID, tab.panes[max] != nil {
            frames = [max: bounds]
        } else {
            frames = tab.layout.layout(in: bounds, spacing: Self.spacing)
        }
        for (id, view) in paneViews {
            if let f = frames[id] {
                view.isHidden = false
                view.frame = f
                view.showsFocusRing = multiple && tab.focusedPaneID == id
            } else {
                view.isHidden = true
            }
        }
        layoutDividers(enabled: tab.maximizedPaneID == nil)
        layer?.backgroundColor = AppServices.shared.theme.chrome.border.nsColor.cgColor
    }

    private func syncPaneViews() {
        guard let controller else { return }
        for (id, pane) in tab.panes where paneViews[id] == nil {
            let v = PaneContainerView(pane: pane, controller: controller)
            addSubview(v)
            paneViews[id] = v
        }
        for (id, v) in paneViews where tab.panes[id] == nil {
            v.removeFromSuperview()
            paneViews[id] = nil
        }
    }

    private func layoutDividers(enabled: Bool) {
        let dividers = enabled ? tab.layout.dividers(in: bounds, spacing: Self.spacing, thickness: 6) : []
        while dividerViews.count > dividers.count { dividerViews.removeLast().removeFromSuperview() }
        while dividerViews.count < dividers.count {
            let d = DividerView()
            d.onDrag = { [weak self] divider, point in self?.dragDivider(divider, to: point) }
            addSubview(d)
            dividerViews.append(d)
        }
        for (view, divider) in zip(dividerViews, dividers) {
            view.divider = divider
            view.frame = divider.frame
        }
    }

    private func dragDivider(_ divider: SplitLayout.Divider, to point: CGPoint) {
        let f = divider.containerFrame
        let fraction: Double = divider.orientation == .horizontal
            ? Double((point.x - f.minX) / max(f.width, 1))
            : Double((point.y - f.minY) / max(f.height, 1))
        tab.moveDivider(divider, to: fraction)
        needsLayout = true
    }
}

/// Invisible hit area over the gap between two panes.
@MainActor
final class DividerView: NSView {
    var divider: SplitLayout.Divider?
    var onDrag: ((SplitLayout.Divider, CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        guard let divider else { return }
        addCursorRect(bounds, cursor: divider.orientation == .horizontal ? .resizeLeftRight : .resizeUpDown)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let divider, let parent = superview else { return }
        onDrag?(divider, parent.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2, let parent = superview as? SplitTreeView {
            parent.tab.equalize()
            parent.needsLayout = true
        }
    }
}

/// A pane: the terminal view plus its overlays (focus ring, search bar).
@MainActor
final class PaneContainerView: NSView {
    let pane: TerminalPane
    let engine: SwiftTermEngine
    private weak var controller: MainWindowController?
    private var searchHost: NSHostingView<SearchBarView>?
    private var appearanceLoop: ObservationLoop?
    var showsFocusRing = false { didSet { if oldValue != showsFocusRing { updateRing() } } }

    init(pane: TerminalPane, controller: MainWindowController) {
        self.pane = pane
        self.controller = controller
        engine = SwiftTermEngine(frame: CGRect(x: 0, y: 0, width: 800, height: 600), settings: pane.settings)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0
        addSubview(engine)
        engine.transparentBackground = AppServices.shared.theme.vibrancy
        pane.attach(engine: engine)
        engine.contextMenuProvider = { [weak self] _ in
            guard let self, let controller = self.controller else { return nil }
            return controller.terminalContextMenu(for: self.pane)
        }
        appearanceLoop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = AppServices.shared.theme.revision
            _ = AppServices.shared.configRevision
            _ = self.pane.profile
        }, apply: { [weak self] in
            guard let self else { return }
            let theme = AppServices.shared.theme
            self.engine.transparentBackground = theme.vibrancy
            self.pane.applyAppearance(settings: AppServices.shared.terminalSettings, scheme: theme.scheme(for: self.pane.profile))
            self.updateRing()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        engine.frame = bounds
        if let searchHost {
            let size = searchHost.fittingSize
            searchHost.frame = CGRect(x: bounds.width - size.width - 12, y: 8, width: size.width, height: size.height)
        }
        if !pane.hasStarted && bounds.width > 20 && bounds.height > 20 {
            // Let SwiftTerm compute the grid for this size first.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.pane.startIfNeeded() }
            }
        }
    }

    private func updateRing() {
        layer?.borderWidth = showsFocusRing ? 1 : 0
        layer?.borderColor = AppServices.shared.theme.chrome.accent.nsColor.withAlphaComponent(0.8).cgColor
    }

    // MARK: Search

    var isSearchVisible: Bool { searchHost != nil }

    func showSearch() {
        if searchHost == nil {
            let view = SearchBarView(model: SearchModel(engine: engine), onClose: { [weak self] in
                MainActor.assumeIsolated { self?.hideSearch() }
            })
            let host = NSHostingView(rootView: view)
            addSubview(host)
            searchHost = host
            pane.isSearchVisible = true
            needsLayout = true
        }
        // Focus the field.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let host = self?.searchHost else { return }
                self?.window?.makeFirstResponder(host)
            }
        }
    }

    func hideSearch() {
        searchHost?.removeFromSuperview()
        searchHost = nil
        pane.isSearchVisible = false
        engine.clearSearch()
        window?.makeFirstResponder(engine)
    }

    func toggleSearch() {
        if isSearchVisible { hideSearch() } else { showSearch() }
    }
}
#endif
