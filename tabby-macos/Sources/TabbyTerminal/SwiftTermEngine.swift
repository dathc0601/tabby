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

    /// Where copies go (tests use a private pasteboard).
    public var pasteboard: NSPasteboard = .general

    private var rightClickAction: TerminalSettings.RightClick = .menu
    private var copyOnSelect = false
    private var copyAsHTML = true
    private var wordSeparator = TerminalTextDefaults.wordSeparator
    private var linkModifier: LinkModifier = .none
    /// SwiftTerm opened a link during the current mouse-up.
    private var openedLink = false
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
        copyAsHTML = settings.copyAsHTML
        wordSeparator = settings.wordSeparator
        linkModifier = settings.linkModifier
        // SwiftTerm underlines and opens links itself on a plain click (.hover) or a ⌘-click;
        // for ⌥ and ⇧ (and ⌃ from a Tabby config) TabbyMac looks them up on the click.
        switch linkModifier {
        case .none:
            linkReporting = .implicit
            linkHighlightMode = .hover
        case .command:
            linkReporting = .implicit
            linkHighlightMode = .hoverWithModifier
        case .option, .shift, .control:
            linkReporting = .none
        }
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
        feed(text: "\u{1b}[H\u{1b}[2J") // l10n-ignore: an escape sequence
        // Ask the program to repaint (the shell redraws its prompt).
        engineDelegate?.engine(self, send: Data([0x0c]))
    }

    public func clearScreen() {
        clearScrollback()
        feed(text: "\u{1b}[H\u{1b}[2J") // l10n-ignore: an escape sequence
    }

    public func snapshotText(maxLines: Int) -> String {
        let data = getTerminal().getBufferAsData(kind: .normal)
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    public func bufferText() -> String {
        var lines = String(decoding: getTerminal().getBufferAsData(kind: .normal), as: UTF8.self).components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n") + "\n"
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
        engineDelegate?.engineClicked(self)
        // SwiftTerm's double-click word is fixed (letters, digits, "._-"); Tabby's stops at
        // `terminal.wordSeparator`.
        if event.clickCount == 2, let (column, row) = cell(at: convert(event.locationInWindow, from: nil)) {
            selectWord(column: column, row: row)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        openedLink = false
        super.mouseUp(with: event)
        if copyOnSelect { _ = copySelection() }
        if event.clickCount == 1, !openedLink, !selectionActive,
           let (column, row) = cell(at: convert(event.locationInWindow, from: nil)) {
            clickLink(column: column, row: row, modifiers: event.modifierFlags)
        }
    }

    /// A click on a cell: opens the link there when the key Tabby's setting asks for is held —
    /// one SwiftTerm leaves to TabbyMac (⌥/⇧ modes) or a form it doesn't detect (a bare IPv4
    /// address, `www.…`).
    func clickLink(column: Int, row: Int, modifiers: NSEvent.ModifierFlags) {
        let held: Bool
        switch linkModifier {
        case .none: held = true
        case .option: held = modifiers.contains(.option)
        case .shift: held = modifiers.contains(.shift)
        case .command: held = modifiers.contains(.command)
        case .control: held = modifiers.contains(.control)
        }
        guard held else { return }
        let t = getTerminal()
        if linkReporting == .none, let link = t.link(at: .screen(Position(col: column, row: row)), mode: .explicitAndImplicit) {
            engineDelegate?.engine(self, openLink: link)
            return
        }
        let bufferRow = row + t.buffer.yDisp
        guard let line = t.getScrollInvariantLine(row: bufferRow + t.buffer.totalLinesTrimmed) else { return }
        let text = String((0..<min(line.count, t.cols)).map { i -> Character in
            let cd = line[i]
            let ch = cd.width == 0 ? " " : t.getCharacter(for: cd)
            return ch == "\0" ? " " : ch
        })
        if let link = LinkDetector.match(in: text, at: column) {
            engineDelegate?.engine(self, openLink: link)
        }
    }

    /// The visible cell under `point` (column, row from the top of the screen).
    private func cell(at point: CGPoint) -> (Int, Int)? {
        let t = getTerminal()
        guard t.cols > 0, t.rows > 0 else { return nil }
        let height = getOptimalFrameSize().height / CGFloat(t.rows)
        let glyph = font.glyph(withName: "W")
        let scale = window?.backingScaleFactor ?? 2
        let width = max(1, (font.advancement(forGlyph: glyph).width * scale).rounded() / scale)
        guard height > 0 else { return nil }
        return (min(max(Int(point.x / width), 0), t.cols - 1), min(max(Int((frame.height - point.y) / height), 0), t.rows - 1))
    }

    /// Selects the word around a visible cell, stopping at `terminal.wordSeparator`.
    func selectWord(column: Int, row: Int) {
        let t = getTerminal()
        let bufferRow = row + t.buffer.yDisp
        guard let line = t.getScrollInvariantLine(row: bufferRow + t.buffer.totalLinesTrimmed) else { return }
        let cells: [Character?] = (0..<min(line.count, t.cols)).map { i in
            let cd = line[i]
            return cd.width == 0 ? nil : t.getCharacter(for: cd)
        }
        guard let range = WordSelection.range(in: cells, at: column, separators: wordSeparator) else { return }
        // SwiftTerm's selection end is one past the last column.
        selection.setSelection(start: Position(col: range.lowerBound, row: bufferRow),
                               end: Position(col: range.upperBound + 1, row: bufferRow))
        needsDisplay = true
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
            if copySelection() {
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
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        engineDelegate?.engine(self, paste: text)
    }

    /// Copies the selection as text and, with "Copy with formatting", as HTML too (Tabby's
    /// `copySelection`: below 32 KiB only).
    public func copySelection() -> Bool {
        guard let text = selectedText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let html = copyAsHTML && TerminalHTML.shouldInclude(textLength: text.count) ? selectionHTML() : nil
        pasteboard.clearContents()
        pasteboard.declareTypes(html == nil ? [.string] : [.string, .html], owner: nil)
        pasteboard.setString(text, forType: .string)
        if let html { pasteboard.setString(html, forType: .html) }
        return true
    }

    private func selectionHTML() -> String? {
        guard let (scheme, _) = lastApplied.map({ ($0.1, $0.2) }) else { return nil }
        let lines = styledSelection()
        guard !lines.isEmpty else { return nil }
        return TerminalHTML.render(lines: lines, scheme: scheme, fontFamily: font.familyName ?? font.fontName,
                                   brightBold: lastApplied?.0.drawBoldTextInBrightColors ?? true)
    }

    /// The selected cells with their attributes, one array per line (wrapped rows joined).
    func styledSelection() -> [[StyledCell]] {
        guard selectionActive, let selection else { return [] }
        let t = getTerminal()
        var (start, end) = (selection.start, selection.end)
        if Position.compare(start, end) == .after { swap(&start, &end) }
        var lines: [[StyledCell]] = []
        for row in start.row...max(start.row, end.row) {
            guard let line = t.getScrollInvariantLine(row: row + t.buffer.totalLinesTrimmed) else { continue }
            let from = row == start.row ? start.col : 0
            let to = row == end.row ? min(end.col, line.count) : min(t.cols, line.count)
            var cells: [StyledCell] = []
            if from < to {
                for i in from..<to {
                    let cd = line[i]
                    if cd.width == 0 { continue }
                    cells.append(Self.styledCell(cd, character: t.getCharacter(for: cd)))
                }
            }
            if line.isWrapped, row != start.row, !lines.isEmpty {
                lines[lines.count - 1] += cells
            } else {
                lines.append(cells)
            }
        }
        while let last = lines.last, last.allSatisfy({ $0.text.trimmingCharacters(in: .whitespaces).isEmpty || $0.text == "\0" }) {
            lines.removeLast()
        }
        return lines
    }

    static func styledCell(_ cd: CharData, character: Character) -> StyledCell {
        func color(_ c: Attribute.Color) -> CellColor {
            switch c {
            case .ansi256(let code): return .ansi(Int(code))
            case let .trueColor(r, g, b): return .rgb(r, g, b)
            case .defaultColor, .defaultInvertedColor: return .default
            }
        }
        let a = cd.attribute
        var cell = StyledCell(text: a.style.contains(.invisible) || character == "\0" ? " " : String(character))
        cell.foreground = color(a.fg)
        cell.background = color(a.bg)
        cell.bold = a.style.contains(.bold)
        cell.italic = a.style.contains(.italic)
        cell.underline = a.style.contains(.underline)
        cell.strikethrough = a.style.contains(.crossedOut)
        cell.dim = a.style.contains(.dim)
        cell.inverse = a.style.contains(.inverse)
        return cell
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

    /// SwiftTerm found a link under the click (OSC 8 or its own detection): the pane decides
    /// what it opens (Tabby's linkifier handlers).
    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        openedLink = true
        engineDelegate?.engine(self, openLink: link)
    }

    /// SwiftTerm reports the bell to its delegate only in audible mode; TabbyMac needs it in
    /// every mode (tab activity, the Dock bounce). `super` still beeps or flashes.
    public override func bell(source: Terminal) {
        super.bell(source: source)
        engineDelegate?.engineBell(self)
    }

    /// The audible bell (SwiftTerm calls this from `bell(source: Terminal)` in `.sound` mode).
    public func bell(source: TerminalView) {
        NSSound.beep()
    }

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// `OSC 1337` payloads SwiftTerm doesn't handle itself; TabbyMac reads `CurrentDir=`
    /// (Tabby's `OSCProcessor`).
    public func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        guard let directory = TerminalOSC.iTermCurrentDirectory(String(decoding: content, as: UTF8.self)) else { return }
        engineDelegate?.engine(self, directoryChanged: directory)
    }
}
#endif
