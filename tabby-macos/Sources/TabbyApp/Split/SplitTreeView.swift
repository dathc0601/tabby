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
    /// Pane views currently placed in this tab (owned by the window controller's cache).
    private var paneViews: [UUID: PaneContainerView] = [:]
    private var dividerViews: [DividerView] = []
    private var loop: ObservationLoop?
    private let dropOverlay = DropZoneOverlay()
    private var maximizedHost: NSHostingView<MaximizedChip>?
    static let spacing: CGFloat = 1

    init(tab: TabModel, controller: MainWindowController) {
        self.tab = tab
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        dropOverlay.isHidden = true
        addSubview(dropOverlay)
        // Tab headers drag their id as text (SwiftUI `.draggable`); dropping one on a pane
        // splits it.
        registerForDraggedTypes([.string])
        loop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            // Read what the layout depends on so changes trigger a relayout.
            _ = self.tab.layout
            _ = self.tab.panes.count
            _ = self.tab.maximizedPaneID
            _ = self.tab.focusedPaneID
            _ = self.tab.broadcastInput
            _ = AppServices.shared.theme.revision
        }, apply: { [weak self] in
            self?.syncPaneViews()
            self?.needsLayout = true
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func paneView(for id: UUID) -> PaneContainerView? {
        syncPaneViews()
        return paneViews[id]
    }

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
                // Every pane looks focused while input goes to all of them, as in Tabby.
                let focused = tab.broadcastInput || tab.focusedPaneID == id
                view.showsFocusRing = multiple && focused && tab.maximizedPaneID == nil
                view.isDimmed = multiple && !focused && tab.maximizedPaneID == nil
            } else {
                view.isHidden = true
            }
        }
        layoutDividers(enabled: tab.maximizedPaneID == nil)
        layer?.backgroundColor = AppServices.shared.theme.chrome.separator.nsColor.cgColor
        layoutMaximizedChip()
        addSubview(dropOverlay, positioned: .above, relativeTo: nil)
    }

    private func layoutMaximizedChip() {
        if tab.maximizedPaneID != nil {
            if maximizedHost == nil {
                let host = NSHostingView(rootView: MaximizedChip(tab: tab) { [weak self] in
                    guard let self else { return }
                    self.tab.maximizedPaneID = nil
                    self.needsLayout = true
                })
                host.safeAreaRegions = []
                addSubview(host)
                maximizedHost = host
            }
            if let host = maximizedHost {
                addSubview(host, positioned: .above, relativeTo: nil)
                let size = host.fittingSize
                host.frame = CGRect(x: (bounds.width - size.width) / 2, y: bounds.height - size.height - 6, width: size.width, height: size.height)
            }
        } else {
            maximizedHost?.removeFromSuperview()
            maximizedHost = nil
        }
    }

    // MARK: Dropping a tab on a pane

    private func draggedTab(_ info: NSDraggingInfo) -> UUID? {
        guard let text = info.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: text),
              id != tab.id, tab.content == nil,
              let source = controller?.model.tabs.first(where: { $0.id == id }), source.content == nil else { return nil }
        return id
    }

    private func dropTarget(_ info: NSDraggingInfo) -> (pane: UUID, frame: CGRect, side: SplitDirection)? {
        guard draggedTab(info) != nil else { return nil }
        let point = convert(info.draggingLocation, from: nil)
        guard let (id, view) = paneViews.first(where: { !$0.value.isHidden && $0.value.frame.contains(point) }) else { return nil }
        return (id, view.frame, SplitDirection.dropSide(at: point, in: view.frame))
    }

    private func updateDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let target = dropTarget(info) else {
            dropOverlay.isHidden = true
            return []
        }
        dropOverlay.frame = target.frame
        dropOverlay.side = target.side
        dropOverlay.isHidden = false
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { dropOverlay.isHidden = true }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { dropOverlay.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        guard let id = draggedTab(sender), let target = dropTarget(sender) else { return false }
        return controller?.model.dropTab(id, onto: target.pane, side: target.side) ?? false
    }

    func syncPaneViews() {
        guard let controller else { return }
        for (id, pane) in tab.panes where paneViews[id] == nil || paneViews[id]?.superview !== self {
            // Re-use the pane's existing view (and terminal buffer) when it moved here from another tab.
            let v = controller.paneContainer(for: pane)
            if let first = dividerViews.first {
                addSubview(v, positioned: .below, relativeTo: first)
            } else {
                addSubview(v)
            }
            paneViews[id] = v
        }
        var removed = false
        for (id, v) in paneViews where tab.panes[id] == nil {
            if v.superview === self { v.removeFromSuperview() }
            paneViews[id] = nil
            removed = true
        }
        if removed { controller.prunePaneViews() }
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

/// Hit area over the 1 pt gap between two panes (6 pt wide); shows an accent grip on hover.
@MainActor
final class DividerView: NSView {
    var divider: SplitLayout.Divider?
    var onDrag: ((SplitLayout.Divider, CGPoint) -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering, let divider else { return }
        AppServices.shared.theme.chrome.accent.nsColor.setFill()
        let grip: CGRect = divider.orientation == .horizontal
            ? CGRect(x: bounds.midX - 1.5, y: bounds.midY - 14, width: 3, height: 28)
            : CGRect(x: bounds.midX - 14, y: bounds.midY - 1.5, width: 28, height: 3)
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }

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

/// A view that never takes the mouse (the dim layer over unfocused panes).
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A pane: the terminal view plus its overlays (focus ring, search bar).
@MainActor
final class PaneContainerView: NSView {
    let pane: TerminalPane
    let engine: SwiftTermEngine
    private weak var controller: MainWindowController?
    private var searchHost: NSHostingView<SearchBarView>?
    private var chipHost: NSHostingView<SSHStatusChip>?
    private let hover = PaneHover()
    private var appearanceLoop: ObservationLoop?
    private var chipLoop: ObservationLoop?
    var showsFocusRing = false { didSet { if oldValue != showsFocusRing { updateRing() } } }
    /// Unfocused panes of a split dim by 25% (the design).
    var isDimmed = false { didSet { if oldValue != isDimmed { updateRing() } } }
    private let dimView = PassThroughView()

    init(pane: TerminalPane, controller: MainWindowController) {
        self.pane = pane
        self.controller = controller
        engine = SwiftTermEngine(frame: CGRect(x: 0, y: 0, width: 800, height: 600), settings: pane.settings)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0
        addSubview(engine)
        if pane.profile.type != "local" {
            let chip = NSHostingView(rootView: SSHStatusChip(pane: pane, hover: hover))
            chip.safeAreaRegions = []
            addSubview(chip)
            chipHost = chip
        }
        engine.transparentBackground = AppServices.shared.theme.vibrancy
        pane.attach(engine: engine)
        engine.contextMenuProvider = { [weak self] _ in
            guard let self, let controller = self.controller else { return nil }
            return controller.terminalContextMenu(for: self.pane)
        }
        if chipHost != nil {
            // The chip changes size with the state and on hover; keep its frame fitted.
            chipLoop = ObservationLoop(track: { [weak self] in
                _ = self?.pane.connectionState
                _ = self?.hover.isHovering
            }, apply: { [weak self] in self?.needsLayout = true })
        }
        appearanceLoop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = AppServices.shared.theme.revision
            _ = AppServices.shared.configRevision
            _ = self.pane.profile
        }, apply: { [weak self] in
            guard let self else { return }
            let theme = AppServices.shared.theme
            let scheme = theme.scheme(for: self.pane.profile)
            self.engine.transparentBackground = theme.vibrancy
            self.pane.applyAppearance(settings: AppServices.shared.terminalSettings, scheme: scheme)
            // The margin around the terminal shows its background (Tabby binds the tab's
            // background colour to the scheme's); with vibrancy the window shows through.
            self.layer?.backgroundColor = theme.vibrancy ? nil : scheme.backgroundRGB.nsColor.cgColor
            self.needsLayout = true
            self.updateRing()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let margin = CGFloat(AppServices.shared.theme.metrics.terminalMargin)
        engine.frame = bounds.insetBy(dx: margin, dy: margin)
        dimView.frame = bounds
        if let chipHost {
            let size = chipHost.fittingSize
            chipHost.frame = CGRect(x: 4, y: 4, width: max(size.width, 1), height: max(size.height, 1))
        }
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

    // MARK: Hover (status chip)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hover.isHovering = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        hover.isHovering = false
        needsLayout = true
    }

    private func updateRing() {
        let chrome = AppServices.shared.theme.chrome
        layer?.borderWidth = showsFocusRing ? 1.5 : 0
        layer?.borderColor = chrome.accent.nsColor.cgColor
        if dimView.superview == nil {
            dimView.wantsLayer = true
            addSubview(dimView, positioned: .above, relativeTo: engine)
        }
        dimView.layer?.backgroundColor = chrome.surface.withAlpha(0.25).nsColor.cgColor
        dimView.isHidden = !isDimmed
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
