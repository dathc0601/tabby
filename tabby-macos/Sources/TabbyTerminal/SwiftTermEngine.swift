#if canImport(AppKit)
import AppKit
import SwiftTerm
import TabbyCore

/// The macOS terminal view: SwiftTerm's `TerminalView` adapted to `TerminalEngine`.
///
/// SwiftTerm handles VT parsing, rendering, selection, mouse reporting and IME. This class
/// maps Tabby's settings onto it, forwards events to the pane, and implements Tabby's mouse
/// conventions (right-click action, middle-click paste, copy on select).
public final class SwiftTermEngine: TerminalView, TerminalEngine, TerminalViewDelegate {
    public weak var engineDelegate: TerminalEngineDelegate?

    /// Builds the context menu for a right click (set by the app).
    public var contextMenuProvider: ((SwiftTermEngine) -> NSMenu?)?
    /// When true the terminal background is transparent so window vibrancy shows through.
    public var transparentBackground = false {
        didSet { if oldValue != transparentBackground, let s = lastApplied { apply(settings: s.0, scheme: s.1, fontSize: s.2) } }
    }

    private var rightClickAction: TerminalSettings.RightClick = .menu
    private var copyOnSelect = false
    private var pasteOnMiddleClick = true
    private var appliedScrollback = 0
    private var lastApplied: (TerminalSettings, ColorScheme, Double)?

    public init(frame: CGRect, settings: TerminalSettings) {
        let options = TerminalOptions(
            termName: "xterm-256color",
            cursorStyle: Self.cursorStyle(settings),
            scrollback: settings.scrollbackLines
        )
        super.init(frame: frame, font: Self.font(for: settings, size: settings.fontSize), options: options)
        appliedScrollback = settings.scrollbackLines
        terminalDelegate = self
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: Appearance

    static func cursorStyle(_ s: TerminalSettings) -> CursorStyle {
        switch (s.cursor, s.cursorBlink) {
        case (.block, true): return .blinkBlock
        case (.block, false): return .steadyBlock
        case (.beam, true): return .blinkBar
        case (.beam, false): return .steadyBar
        case (.underline, true): return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        }
    }

    static func font(for s: TerminalSettings, size: Double) -> NSFont {
        let pointSize = CGFloat(size)
        var base = NSFont(name: s.fontName, size: pointSize)
            ?? s.fallbackFont.flatMap { NSFont(name: $0, size: pointSize) }
            ?? NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
        if s.fontWeight != 400, let family = base.familyName {
            // NSFontManager weights run 0...15 with 5 = regular and 9 = bold.
            let weight = max(0, min(15, Int((Double(s.fontWeight) / 100.0 - 4.0) * 1.33 + 5.0)))
            if let weighted = NSFontManager.shared.font(withFamily: family, traits: [], weight: weight, size: pointSize) {
                base = weighted
            }
        }
        return base
    }

    public func apply(settings: TerminalSettings, scheme: ColorScheme, fontSize: Double) {
        lastApplied = (settings, scheme, fontSize)
        let newFont = Self.font(for: settings, size: fontSize)
        if newFont.fontName != font.fontName || newFont.pointSize != font.pointSize {
            font = newFont
        }
        installColors(scheme.paletteRGB.map(Self.terminalColor))
        nativeForegroundColor = Self.nsColor(scheme.foregroundRGB)
        nativeBackgroundColor = transparentBackground ? Self.nsColor(scheme.backgroundRGB).withAlphaComponent(0) : Self.nsColor(scheme.backgroundRGB)
        caretColor = Self.nsColor(scheme.cursorRGB)
        if let sel = scheme.selection.flatMap(TabbyCore.RGBColor.init(hex:)) {
            selectedTextBackgroundColor = Self.nsColor(sel)
        } else {
            selectedTextBackgroundColor = Self.nsColor(scheme.foregroundRGB).withAlphaComponent(0.3)
        }
        getTerminal().setCursorStyle(Self.cursorStyle(settings))
        optionAsMetaKey = settings.altIsMeta
        useBrightColors = settings.drawBoldTextInBrightColors
        switch settings.bell {
        case .off: bellStyle = .none
        case .visual: bellStyle = .visual
        case .audible: bellStyle = .sound
        }
        if settings.scrollbackLines != appliedScrollback {
            changeScrollback(settings.scrollbackLines)
            appliedScrollback = settings.scrollbackLines
        }
        rightClickAction = settings.rightClick
        copyOnSelect = settings.copyOnSelect
        pasteOnMiddleClick = settings.pasteOnMiddleClick
        needsDisplay = true
    }

    static func terminalColor(_ c: TabbyCore.RGBColor) -> SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16((c.r * 255).rounded()), green8: UInt16((c.g * 255).rounded()), blue8: UInt16((c.b * 255).rounded()))
    }

    static func nsColor(_ c: TabbyCore.RGBColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    // MARK: TerminalEngine

    public var gridSize: (cols: Int, rows: Int) {
        let t = getTerminal()
        return (t.cols, t.rows)
    }

    public var isAlternateScreen: Bool { getTerminal().isCurrentBufferAlternate }
    public var isBracketedPasteMode: Bool { getTerminal().bracketedPasteMode }
    public var hasSelection: Bool { selectionActive }

    public func feed(_ data: Data) {
        // Chunks from the PTY are at most 64 KB; SwiftTerm coalesces redraws.
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            feed(byteArray: ArraySlice(bytes))
        }
    }

    public func selectedText() -> String? {
        guard selectionActive else { return nil }
        let s = selection.getSelectedText()
        return s.isEmpty ? nil : s
    }

    public func clearSelection() {
        selectNone()
    }

    public func clearBuffer() {
        clearScrollback()
        feed(text: "\u{1b}[H\u{1b}[2J")
        // Ask the program to repaint (the shell redraws its prompt).
        engineDelegate?.engine(self, send: Data([0x0c]))
    }

    public func snapshotText(maxLines: Int) -> String {
        let data = getTerminal().getBufferAsData(kind: .normal)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    public func scroll(_ action: TerminalScrollAction) {
        switch action {
        case .top: scroll(toPosition: 0)
        case .bottom: scroll(toPosition: 1)
        case .pageUp: pageUp()
        case .pageDown: pageDown()
        case .lineUp: scrollUp(lines: 1)
        case .lineDown: scrollDown(lines: 1)
        }
    }

    public func focus() {
        window?.makeFirstResponder(self)
    }

    public func find(_ query: String, options: TerminalSearchOptions, backwards: Bool) -> Bool {
        let o = SearchOptions(caseSensitive: options.caseSensitive, regex: options.regex, wholeWord: options.wholeWord)
        return backwards ? findPrevious(query, options: o) : findNext(query, options: o)
    }

    public func searchSummary(_ query: String, options: TerminalSearchOptions) -> (index: Int, total: Int) {
        let o = SearchOptions(caseSensitive: options.caseSensitive, regex: options.regex, wholeWord: options.wholeWord)
        return searchMatchSummary(query, options: o)
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        engineDelegate?.engineDidFocus(self)
    }

    public override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        if copyOnSelect, let text = selectedText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        engineDelegate?.engineDidFocus(self)
        switch rightClickAction {
        case .menu:
            super.rightMouseDown(with: event)
        case .paste:
            pasteFromClipboard()
        case .clipboard:
            if let text = selectedText() {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                selectNone()
            } else {
                pasteFromClipboard()
            }
        case .off:
            break
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard rightClickAction == .menu else { return nil }
        return contextMenuProvider?(self)
    }

    public override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 && pasteOnMiddleClick {
            pasteFromClipboard()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    // MARK: Clipboard

    /// Edit > Paste and ⌘V route through the pane so Tabby's paste rules apply.
    public override func paste(_ sender: Any) {
        pasteFromClipboard()
    }

    /// Edit > Copy: leave the clipboard alone when nothing is selected.
    public override func copy(_ sender: Any) {
        _ = copySelection()
    }

    public func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        engineDelegate?.engine(self, paste: text)
    }

    public func copySelection() -> Bool {
        guard let text = selectedText() else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    // MARK: TerminalViewDelegate

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        engineDelegate?.engine(self, resized: newCols, rows: newRows)
    }

    public func setTerminalTitle(source: TerminalView, title: String) {
        engineDelegate?.engine(self, titleChanged: title)
    }

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        engineDelegate?.engine(self, directoryChanged: directory)
    }

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        engineDelegate?.engine(self, send: Data(data))
    }

    public func scrolled(source: TerminalView, position: Double) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if link.hasPrefix("/") || link.hasPrefix("~") {
            NSWorkspace.shared.open(URL(fileURLWithPath: (link as NSString).expandingTildeInPath))
        }
    }

    public func bell(source: TerminalView) {
        NSSound.beep()
        engineDelegate?.engineBell(self)
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
#endif
