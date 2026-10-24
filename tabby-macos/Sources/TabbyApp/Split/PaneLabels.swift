#if canImport(AppKit)
import AppKit
import TabbyCore

/// A pane's custom title at its top centre (Tabby's `splitTabPaneLabel`: white 12 px text on
/// 70 % black, one line with an ellipsis).
final class PaneTitleLabel: NSView {
    private let field = NSTextField(labelWithString: "")

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 4
        field.font = .systemFont(ofSize: 12)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The natural size, at most `maxWidth` wide.
    func size(maxWidth: CGFloat) -> CGSize {
        let text = field.intrinsicContentSize
        return CGSize(width: min(ceil(text.width) + 20, maxWidth), height: ceil(text.height) + 6)
    }

    override func layout() {
        super.layout()
        let h = field.intrinsicContentSize.height
        field.frame = CGRect(x: 8, y: (bounds.height - h) / 2, width: bounds.width - 16, height: h)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The rearranging overlay of one pane (Tabby's `.rearrange-overlay`): 50 % black, with a
/// label in the middle that can be dragged onto another place in the split or the tab bar.
final class RearrangeOverlayView: NSView {
    let label: PaneDragLabel

    init(paneID: UUID, title: String, onDragEnded: @escaping () -> Void) {
        label = PaneDragLabel(paneID: paneID, title: title, onDragEnded: onDragEnded)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let size = label.size(maxWidth: bounds.width - 24)
        label.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    /// Clicks on the overlay go nowhere (not to the terminal under it); the label drags.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return label.frame.contains(local) ? label : self
    }
}

/// The draggable label: the pane's id goes on the pasteboard as `tabbymac-pane:<uuid>`.
final class PaneDragLabel: NSView, NSDraggingSource {
    static let pasteboardPrefix = "tabbymac-pane:" // l10n-ignore: pasteboard syntax
    /// A pane is being dragged (releasing ⌃⇧ then keeps the labels until the drop).
    static private(set) var isDragging = false

    let paneID: UUID
    private let icon = NSImageView()
    private let field = NSTextField(labelWithString: "")
    private let onDragEnded: () -> Void

    init(paneID: UUID, title: String, onDragEnded: @escaping () -> Void) {
        self.paneID = paneID
        self.onDragEnded = onDragEnded
        super.init(frame: .zero)
        wantsLayer = true
        let chrome = AppServices.shared.theme.chrome
        layer?.backgroundColor = chrome.surfaceChrome.nsColor.cgColor
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = chrome.border.nsColor.cgColor
        icon.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        icon.contentTintColor = chrome.textMuted.nsColor
        field.stringValue = title
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = chrome.text.nsColor
        field.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(field)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func size(maxWidth: CGFloat) -> CGSize {
        CGSize(width: min(field.intrinsicContentSize.width + 46, max(60, maxWidth)), height: 30)
    }

    override func layout() {
        super.layout()
        icon.frame = CGRect(x: 10, y: 7, width: 16, height: 16)
        let h = field.intrinsicContentSize.height
        field.frame = CGRect(x: 32, y: (bounds.height - h) / 2, width: bounds.width - 42, height: h)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard !Self.isDragging else { return }
        let item = NSDraggingItem(pasteboardWriter: (Self.pasteboardPrefix + paneID.uuidString) as NSString)
        let image = bitmapImageRepForCachingDisplay(in: bounds).map { rep -> NSImage in
            cacheDisplay(in: bounds, to: rep)
            let image = NSImage(size: bounds.size)
            image.addRepresentation(rep)
            return image
        }
        item.setDraggingFrame(bounds, contents: image)
        Self.isDragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.isDragging = false
        onDragEnded()
    }

    /// The pane id of a dragged label, if the pasteboard text is one.
    static func paneID(from text: String?) -> UUID? {
        guard let text, text.hasPrefix(pasteboardPrefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(pasteboardPrefix.count)))
    }
}
#endif
