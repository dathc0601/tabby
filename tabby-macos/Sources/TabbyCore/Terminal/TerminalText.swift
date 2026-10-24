// l10n-ignore-file: HTML markup and separator characters, nothing shown as text.
import Foundation

public enum TerminalTextDefaults {
    /// Tabby's `terminal.wordSeparator` default (`tabby-terminal/src/config.ts`).
    public static let wordSeparator = " ()[]{}'\"" // l10n-ignore: characters, not words
}

/// A cell's colour as the terminal stores it.
public enum CellColor: Equatable, Sendable {
    case `default`
    /// 0–15 the scheme's colours, 16–231 the 6×6×6 cube, 232–255 the grey ramp.
    case ansi(Int)
    case rgb(UInt8, UInt8, UInt8)
}

/// One terminal cell with the attributes "Copy with formatting" keeps.
public struct StyledCell: Equatable, Sendable {
    public var text: String
    public var foreground: CellColor = .default
    public var background: CellColor = .default
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var dim = false
    public var inverse = false

    public init(text: String) { self.text = text }
}

/// Tabby's "Copy with formatting" (`terminal.copyAsHTML`): the selection as HTML, like
/// xterm's serialize addon with `includeGlobalBackground` — a `<pre>` in the scheme's colours
/// and one `<span>` per run of equal attributes.
public enum TerminalHTML {
    /// Tabby adds HTML only to copies shorter than 32 KiB (`xtermFrontend.ts`).
    public static func shouldInclude(textLength: Int) -> Bool { textLength < 32 * 1024 }

    public static func render(lines: [[StyledCell]], scheme: ColorScheme, fontFamily: String, brightBold: Bool) -> String {
        let foreground = scheme.foregroundRGB.hex, background = scheme.backgroundRGB.hex
        let palette = scheme.paletteRGB.map(\.hex)
        func hex(_ color: CellColor, bold: Bool) -> String? {
            switch color {
            case .default: return nil
            case .rgb(let r, let g, let b): return String(format: "#%02x%02x%02x", r, g, b)
            case .ansi(var n):
                if bold && brightBold && n < 8 { n += 8 }
                if n < 16 { return n < palette.count ? palette[n] : nil }
                if n < 232 {
                    let levels = [0, 95, 135, 175, 215, 255], i = n - 16
                    return String(format: "#%02x%02x%02x", levels[i / 36], levels[(i / 6) % 6], levels[i % 6])
                }
                let grey = 8 + (min(n, 255) - 232) * 10
                return String(format: "#%02x%02x%02x", grey, grey, grey)
            }
        }
        func style(_ c: StyledCell) -> String {
            var fg = hex(c.foreground, bold: c.bold), bg = hex(c.background, bold: false)
            if c.inverse { (fg, bg) = (bg ?? background, fg ?? foreground) }
            var css = ""
            if let fg { css += "color:\(fg);" }
            if let bg { css += "background-color:\(bg);" }
            if c.bold { css += "font-weight:bold;" }
            if c.italic { css += "font-style:italic;" }
            let decorations = [c.underline ? "underline" : nil, c.strikethrough ? "line-through" : nil].compactMap { $0 }
            if !decorations.isEmpty { css += "text-decoration:\(decorations.joined(separator: " "));" }
            if c.dim { css += "opacity:0.5;" }
            return css
        }
        func escape(_ s: String) -> String {
            var out = ""
            for ch in s {
                switch ch {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                default: out.append(ch)
                }
            }
            return out
        }
        var body: [String] = []
        for line in lines {
            var cells = line
            // Trailing blanks without a background of their own add nothing.
            while let last = cells.last, last.text.allSatisfy({ $0 == " " || $0 == "\0" }), last.background == .default, !last.inverse {
                cells.removeLast()
            }
            var html = "", run = "", runStyle: String?
            func flush() {
                guard !run.isEmpty else { return }
                if let s = runStyle, !s.isEmpty { html += "<span style=\"\(s)\">\(escape(run))</span>" } else { html += escape(run) }
                run = ""
            }
            for cell in cells {
                let s = style(cell)
                if s != runStyle { flush(); runStyle = s }
                run += cell.text.replacingOccurrences(of: "\0", with: " ")
            }
            flush()
            body.append(html)
        }
        let pre = "background-color:\(background);color:\(foreground);font-family:'\(fontFamily)',monospace;"
        return "<pre style=\"\(pre)\">" + body.joined(separator: "\n") + "</pre>"
    }
}

/// Double-click word selection with Tabby's `terminal.wordSeparator`.
public enum WordSelection {
    /// The cells to select around `col` in a row of cells (`nil` = the second half of a wide
    /// character). A space selects the run of spaces; another separator selects itself.
    public static func range(in cells: [Character?], at col: Int, separators: String) -> ClosedRange<Int>? {
        guard cells.indices.contains(col) else { return nil }
        var base = col
        while base > 0, cells[base] == nil { base -= 1 }
        guard let ch = cells[base] else { return nil }
        let separators = Set(separators)
        func isWord(_ c: Character?) -> Bool {
            guard let c else { return true }
            return c != " " && c != "\0" && !separators.contains(c)
        }
        let matches: (Character?) -> Bool
        if ch == " " {
            matches = { $0 == " " }
        } else if !isWord(ch) {
            var end = base
            while end + 1 < cells.count, cells[end + 1] == nil { end += 1 }
            return base...end
        } else {
            matches = isWord
        }
        var start = base, end = base
        while start > 0, matches(cells[start - 1]) { start -= 1 }
        while end + 1 < cells.count, matches(cells[end + 1]) { end += 1 }
        return start...end
    }
}
