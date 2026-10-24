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
            _ = self.tab.isRearranging
            for pane in self.tab.orderedPanes {
                _ = pane.customTitle
                _ = pane.customTitleVisible
                _ = pane.title
            }
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
                view.labelIndex = multiple && tab.maximizedPaneID == nil ? tab.layout.panes.firstIndex(of: id).map { $0 + 1 } : nil
                // Tabby: the custom title label, hidden while another pane is maximized and
                // while the rearranging overlay shows.
                let pane = view.pane
                let named = pane.customTitle.flatMap { $0.isEmpty ? nil : $0 }
                view.customLabel = pane.customTitleVisible && !tab.isRearranging && (tab.maximizedPaneID == nil || tab.maximizedPaneID == id) ? named : nil
                view.rearrangeTitle = tab.isRearranging && tab.maximizedPaneID == nil ? pane.title : nil
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

    // MARK: Dropping a tab or a pane label on a pane

    /// Where a dragged pane label would go: an outer edge of the whole layout (`relativeTo`
    /// nil) or one side of another pane (Tabby's drop zones insert; nothing swaps).
    struct PaneDropZone: Equatable {
        let relativeTo: UUID?
        let side: SplitDirection
        let frame: CGRect
    }

    /// The width of the outer edge zones.
    static let outerEdge: CGFloat = 24

    static func paneDropZone(at p: CGPoint, bounds: CGRect, frames: [UUID: CGRect], dragged: UUID) -> PaneDropZone? {
        guard bounds.contains(p) else { return nil }
        if p.x < bounds.minX + outerEdge { return PaneDropZone(relativeTo: nil, side: .left, frame: bounds) }
        if p.x > bounds.maxX - outerEdge { return PaneDropZone(relativeTo: nil, side: .right, frame: bounds) }
        if p.y < bounds.minY + outerEdge { return PaneDropZone(relativeTo: nil, side: .top, frame: bounds) }
        if p.y > bounds.maxY - outerEdge { return PaneDropZone(relativeTo: nil, side: .bottom, frame: bounds) }
        guard let (id, f) = frames.first(where: { $0.value.contains(p) }), id != dragged else { return nil }
        return PaneDropZone(relativeTo: id, side: SplitDirection.dropSide(at: p, in: f), frame: f)
    }

    private func draggedPane(_ info: NSDraggingInfo) -> UUID? {
        guard let id = PaneDragLabel.paneID(from: info.draggingPasteboard.string(forType: .string)),
              tab.panes[id] != nil, tab.panes.count > 1 else { return nil }
        return id
    }

    private func paneZone(_ info: NSDraggingInfo) -> PaneDropZone? {
        guard let id = draggedPane(info) else { return nil }
        let frames = paneViews.filter { !$0.value.isHidden }.mapValues(\.frame)
        return Self.paneDropZone(at: convert(info.draggingLocation, from: nil), bounds: bounds, frames: frames, dragged: id)
    }

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
        if draggedPane(info) != nil {
            guard let zone = paneZone(info) else {
                dropOverlay.isHidden = true
                return []
            }
            dropOverlay.frame = zone.frame
            dropOverlay.side = zone.side
            dropOverlay.isHidden = false
            return .move
        }
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
        if let id = draggedPane(sender) {
            guard let zone = paneZone(sender) else { return false }
            return controller?.model.movePane(id, relativeTo: zone.relativeTo, side: zone.side) ?? false
        }
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

/// Hosts a pane's corner. Clicks go through to the terminal unless the chip shows (a pane
/// label is not a control).
final class CornerHostingView: NSHostingView<ConnectionChip> {
    var passesClicks: () -> Bool = { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicks() ? nil : super.hitTest(point)
    }
}

/// A pane: the terminal view plus its overlays (focus ring, search bar).
@MainActor
final class PaneContainerView: NSView {
    let pane: TerminalPane
    let engine: SwiftTermEngine
    private weak var controller: MainWindowController?
    private var searchHost: NSHostingView<SearchBarView>?
    private var chipHost: CornerHostingView?
    private let overlay = PaneOverlayState()
    private var appearanceLoop: ObservationLoop?
    private var chipLoop: ObservationLoop?
    /// The keyboard-interactive panel while a login asks something (design `sshAuth`).
    private var authHost: NSHostingView<KeyboardInteractivePanel>?
    private var authLoop: ObservationLoop?
    /// The SFTP panel over the lower 80% of the pane, and the strip above it that closes it.
    private var sftpHost: NSHostingView<SFTPPanelView>?
    private var sftpCatcher: SFTPDismissCatcher?
    private var sftpLoop: ObservationLoop?
    var showsFocusRing = false { didSet { if oldValue != showsFocusRing { updateRing() } } }
    /// Unfocused panes of a split dim by 25% (the design).
    var isDimmed = false { didSet { if oldValue != isDimmed { updateRing() } } }
    /// The pane's position in its split (its corner label), nil when alone.
    var labelIndex: Int? {
        get { overlay.labelIndex }
        set { if overlay.labelIndex != newValue { overlay.labelIndex = newValue } }
    }
    private let dimView = PassThroughView()
    private let customLabelView = PaneTitleLabel()
    private var rearrangeOverlay: RearrangeOverlayView?

    /// The pane's custom title shown at its top (Tabby's pane label); nil hides it.
    var customLabel: String? {
        didSet {
            guard oldValue != customLabel else { return }
            customLabelView.text = customLabel ?? ""
            customLabelView.isHidden = customLabel == nil
            needsLayout = true
        }
    }
    var customLabelFrame: CGRect? { customLabelView.isHidden ? nil : customLabelView.frame }

    /// The title on the rearranging overlay; nil when not rearranging.
    var rearrangeTitle: String? {
        didSet {
            guard oldValue != rearrangeTitle else { return }
            rearrangeOverlay?.removeFromSuperview()
            rearrangeOverlay = nil
            if let rearrangeTitle {
                let paneID = pane.id
                let overlay = RearrangeOverlayView(paneID: paneID, title: rearrangeTitle) { [weak self] in
                    // Tabby: a mouse-up ends the chord, and with it the labels.
                    self?.controller?.model.tabs.first { $0.panes[paneID] != nil }?.isRearranging = false
                }
                addSubview(overlay, positioned: .above, relativeTo: nil)
                rearrangeOverlay = overlay
            }
            needsLayout = true
        }
    }
    var showsRearrangeOverlay: Bool { rearrangeOverlay != nil }

    init(pane: TerminalPane, controller: MainWindowController) {
        self.pane = pane
        self.controller = controller
        engine = SwiftTermEngine(frame: CGRect(x: 0, y: 0, width: 800, height: 600), settings: pane.settings)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 0
        addSubview(engine)
        customLabelView.isHidden = true
        addSubview(customLabelView)
        let chip = CornerHostingView(rootView: ConnectionChip(pane: pane, overlay: overlay))
        chip.safeAreaRegions = []
        chip.passesClicks = { [weak self] in
            guard let self else { return true }
            return PaneCorner.content(state: self.pane.connectionState, hovering: self.overlay.isHovering,
                                      popoverOpen: self.overlay.popoverOpen, labelIndex: self.overlay.labelIndex) != .chip
        }
        addSubview(chip)
        chipHost = chip
        engine.transparentBackground = AppServices.shared.theme.vibrancy
        pane.attach(engine: engine)
        engine.contextMenuProvider = { [weak self] _ in
            guard let self, let controller = self.controller else { return nil }
            return controller.terminalContextMenu(for: self.pane)
        }
        // The chip changes size with the state and on hover, the label with the title; keep
        // the corner's frame fitted.
        chipLoop = ObservationLoop(track: { [weak self] in
            guard let self else { return }
            _ = self.pane.connectionState
            _ = self.overlay.isHovering
            _ = self.overlay.popoverOpen
            _ = self.overlay.labelIndex
            _ = self.pane.title
        }, apply: { [weak self] in
            guard let self else { return }
            self.overlay.connectionChanged(to: self.pane.connectionState)
            self.needsLayout = true
        })
        let paneID = pane.id
        authLoop = ObservationLoop(track: {
            // The prompt index too: Continue and Back put a new field in the panel.
            _ = KeyboardInteractivePanels.shared.models[paneID]?.index
        }, apply: { [weak self] in self?.updateAuthPanel() })
        sftpLoop = ObservationLoop(track: {
            // Editing the path too: the field that replaces the breadcrumb needs the keys.
            _ = SFTPPanels.shared.controllers[paneID]?.model.isEditingPath
        }, apply: { [weak self] in self?.updateSFTPPanel() })
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

    private func updateAuthPanel() {
        let model = KeyboardInteractivePanels.shared.models[pane.id]
        if let model {
            if let authHost, authHost.rootView.model === model {
                // Continue or Back: SwiftUI swaps in the field for the next prompt.
                focusField(in: authHost, secure: model.isSecure)
                return
            }
            authHost?.removeFromSuperview()
            let host = NSHostingView(rootView: KeyboardInteractivePanel(model: model))
            host.safeAreaRegions = []
            addSubview(host)
            authHost = host
            focusField(in: host, secure: model.isSecure)
        } else if let authHost {
            authHost.removeFromSuperview()
            self.authHost = nil
            window?.makeFirstResponder(engine)
        }
        needsLayout = true
    }

    private func updateSFTPPanel() {
        let paneID = pane.id
        if let controller = SFTPPanels.shared.controllers[paneID] {
            if let sftpHost, sftpHost.rootView.controller === controller {
                if controller.model.isEditingPath { focusField(in: sftpHost, placeholder: L("Path")) }
                return
            }
            sftpHost?.removeFromSuperview()
            let host = NSHostingView(rootView: SFTPPanelView(controller: controller, close: { SFTPPanels.shared.close(paneID) }))
            host.safeAreaRegions = []
            let catcher = sftpCatcher ?? SFTPDismissCatcher { SFTPPanels.shared.close(paneID) }
            addSubview(catcher)
            addSubview(host)
            sftpCatcher = catcher
            sftpHost = host
            needsLayout = true
            layoutSubtreeIfNeeded()
            // Slides up over 100 ms (Tabby).
            let final = host.frame
            host.frame = final.offsetBy(dx: 0, dy: final.height)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                host.animator().frame = final
            }
        } else if let sftpHost {
            sftpHost.removeFromSuperview()
            sftpCatcher?.removeFromSuperview()
            self.sftpHost = nil
            sftpCatcher = nil
            window?.makeFirstResponder(engine)
        }
        needsLayout = true
    }

    /// The SSH status chip's frame: the design's top-right corner (8 pt from the top, 12 pt
    /// from the right), under the search bar while that is open. The chip view pads itself by
    /// 8 pt, so the frame sits 8 pt outside the visible capsule.
    static func chipFrame(in bounds: CGRect, size: CGSize, search: CGRect?) -> CGRect {
        let padding: CGFloat = 8
        let top = search.map { $0.maxY + 6 } ?? 8
        return CGRect(x: bounds.maxX - 12 - size.width + padding, y: top - padding, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        if let sftpHost {
            let height = (bounds.height * 0.8).rounded()
            sftpHost.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
            sftpCatcher?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - height)
        }
        // The keyboard-interactive panel pushes the terminal down (the PTY is resized); below
        // it the terminal keeps Tabby's margin.
        let authHeight = authHost.map { $0.fittingSize.height } ?? 0
        authHost?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: authHeight)
        let margin = CGFloat(AppServices.shared.theme.metrics.terminalMargin)
        engine.frame = CGRect(x: 0, y: authHeight, width: bounds.width, height: max(0, bounds.height - authHeight))
            .insetBy(dx: margin, dy: margin)
        dimView.frame = bounds
        if !customLabelView.isHidden {
            let size = customLabelView.size(maxWidth: max(40, bounds.width - 120))
            customLabelView.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: 6, width: size.width, height: size.height)
            addSubview(customLabelView, positioned: .above, relativeTo: dimView.superview == nil ? engine : dimView)
        }
        if let rearrangeOverlay {
            rearrangeOverlay.frame = bounds
            addSubview(rearrangeOverlay, positioned: .above, relativeTo: nil)
        }
        if let searchHost {
            let size = searchHost.fittingSize
            searchHost.frame = CGRect(x: bounds.width - size.width - 12, y: 8, width: size.width, height: size.height)
        }
        if let chipHost {
            let size = chipHost.fittingSize
            chipHost.frame = Self.chipFrame(in: bounds, size: CGSize(width: max(size.width, 1), height: max(size.height, 1)),
                                            search: searchHost?.frame)
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
        overlay.isHovering = true
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        overlay.isHovering = false
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
        if let searchHost { focusField(in: searchHost) }
    }

    /// Puts the keys in the text field of a SwiftUI bar or panel. Making the hosting view first
    /// responder is not enough (the keys stop at the host), and the field may need a turn or
    /// two to exist. `secure` waits for that kind of field (a panel swapping a hidden field
    /// for a plain one still shows the old one for a turn).
    private func focusField(in host: NSView, secure: Bool? = nil, placeholder: String? = nil, attempts: Int = 5) {
        DispatchQueue.main.async { [weak self, weak host] in
            MainActor.assumeIsolated {
                guard let self, let host, host.superview === self else { return }
                if let field = Self.editableTextField(in: host, secure: secure, placeholder: placeholder) {
                    self.window?.makeFirstResponder(field)
                } else if attempts > 0 {
                    self.focusField(in: host, secure: secure, placeholder: placeholder, attempts: attempts - 1)
                }
            }
        }
    }

    private static func editableTextField(in view: NSView, secure: Bool? = nil, placeholder: String? = nil) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable,
           secure.map({ $0 == (field is NSSecureTextField) }) ?? true,
           placeholder.map({ $0 == field.placeholderString }) ?? true {
            return field
        }
        for sub in view.subviews {
            if let field = editableTextField(in: sub, secure: secure, placeholder: placeholder) { return field }
        }
        return nil
    }

    func hideSearch() {
        searchHost?.removeFromSuperview()
        searchHost = nil
        pane.isSearchVisible = false
        engine.clearSearch()
        needsLayout = true  // the chip moves back up
        window?.makeFirstResponder(engine)
    }

    func toggleSearch() {
        if isSearchVisible { hideSearch() } else { showSearch() }
    }
}
/// The terminal strip above an open SFTP panel: a click there closes the panel (Tabby).
final class SFTPDismissCatcher: NSView {
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func dismiss() { onDismiss() }

    override func mouseDown(with event: NSEvent) { dismiss() }
}
#endif
