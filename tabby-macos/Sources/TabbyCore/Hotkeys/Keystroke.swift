import Foundation
// l10n-ignore-file: key and modifier names are Tabby's hotkey syntax (`Ctrl-Shift-T`).

/// A single keystroke in Tabby's notation, e.g. `⌘-Shift-D`, `Ctrl-Tab`, `⌥-Left`, `⌘--`.
///
/// Tabby builds these names in `tabby-core/src/services/hotkeys.util.ts`: modifiers in the
/// fixed order Ctrl, ⌘, ⌥, Shift, joined with `-`, then the key name. Letters are upper
/// case; arrows are `Left`/`Right`/`Up`/`Down`; punctuation is the literal character.
/// The parser also accepts `+` as a separator and the spellings Cmd/Command/Meta,
/// Alt/Option and Control.
public struct Keystroke: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1 << 0)
        public static let command = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var modifiers: Modifiers
    /// Canonical key name, or nil for a modifier-only stroke such as `Ctrl-Shift`.
    public var key: String?

    public init(modifiers: Modifiers, key: String?) {
        self.modifiers = modifiers
        self.key = key.map(Keystroke.canonicalKey)
    }

    private static let modifierNames: [(String, Modifiers)] = [
        ("Ctrl", .control), ("Control", .control), ("⌃", .control),
        ("⌘", .command), ("Cmd", .command), ("Command", .command), ("Meta", .command), ("Super", .command),
        ("⌥", .option), ("Alt", .option), ("Option", .option), ("Opt", .option),
        ("Shift", .shift), ("⇧", .shift),
    ]

    /// Parses Tabby's keystroke notation. Returns nil for empty input.
    public init?(_ string: String) {
        var rest = Substring(string.trimmingCharacters(in: .whitespaces))
        guard !rest.isEmpty else { return nil }
        var mods: Modifiers = []
        var progressed = true
        while progressed {
            progressed = false
            for (name, flag) in Keystroke.modifierNames {
                for sep in ["-", "+"] {
                    let prefix = name + sep
                    if rest.count > prefix.count, rest.lowercased().hasPrefix(prefix.lowercased()) {
                        mods.insert(flag)
                        rest = rest.dropFirst(prefix.count)
                        progressed = true
                    }
                }
            }
        }
        let keyName = String(rest)
        if let (_, flag) = Keystroke.modifierNames.first(where: { $0.0.lowercased() == keyName.lowercased() }) {
            mods.insert(flag)
            self.init(modifiers: mods, key: nil)
        } else {
            self.init(modifiers: mods, key: keyName)
        }
    }

    static let keyAliases: [String: String] = [
        "return": "Enter", "enter": "Enter", "esc": "Escape", "escape": "Escape",
        "space": "Space", " ": "Space", "tab": "Tab", "backspace": "Backspace", "delete": "Delete",
        "del": "Delete", "left": "Left", "right": "Right", "up": "Up", "down": "Down",
        "arrowleft": "Left", "arrowright": "Right", "arrowup": "Up", "arrowdown": "Down",
        "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown", "insert": "Insert",
        "plus": "+", "minus": "-", "equal": "=", "comma": ",", "period": ".", "slash": "/",
        "backslash": "\\", "semicolon": ";", "quote": "'", "bracketleft": "[", "bracketright": "]",
        "backquote": "`",
    ]

    static func canonicalKey(_ key: String) -> String {
        if let alias = keyAliases[key.lowercased()] { return alias }
        if key.count == 1 { return key.uppercased() }
        if key.lowercased().hasPrefix("f"), let n = Int(key.dropFirst()), (1...24).contains(n) { return "F\(n)" }
        if key.hasPrefix("Key"), key.count == 4 { return String(key.dropFirst(3)).uppercased() }
        if key.hasPrefix("Digit"), key.count == 6 { return String(key.dropFirst(5)) }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    /// Tabby's canonical spelling, e.g. `Ctrl-⌘-⌥-Shift-K`.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if let key { parts.append(key) }
        return parts.joined(separator: "-")
    }

    /// macOS menu-style rendering, e.g. `⌃⌥⇧⌘K`.
    public var symbolicDescription: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        switch key {
        case "Left": s += "←"
        case "Right": s += "→"
        case "Up": s += "↑"
        case "Down": s += "↓"
        case "Enter": s += "↩"
        case "Backspace": s += "⌫"
        case "Delete": s += "⌦"
        case "Escape": s += "⎋"
        case "Tab": s += "⇥"
        case "Space": s += "Space"
        case "PageUp": s += "⇞"
        case "PageDown": s += "⇟"
        case "Home": s += "↖"
        case "End": s += "↘"
        case let k?: s += k
        case nil: break
        }
        return s
    }

    public var isModifierOnly: Bool { key == nil }
}

/// One binding: a sequence of keystrokes (length 1 for ordinary shortcuts, more for chords).
public struct HotkeyBinding: Hashable, Sendable, CustomStringConvertible {
    public var strokes: [Keystroke]

    public init(_ strokes: [Keystroke]) {
        self.strokes = strokes
    }

    public init?(_ string: String) {
        guard let k = Keystroke(string) else { return nil }
        self.strokes = [k]
    }

    public var description: String { strokes.map(\.description).joined(separator: ", ") }
    public var symbolicDescription: String { strokes.map(\.symbolicDescription).joined(separator: " ") }

    /// Decodes Tabby's config form: each entry is a string (one stroke) or an array of strings
    /// (a chord); a bare string is accepted for the whole value too.
    public static func bindings(from value: ConfigValue?) -> [HotkeyBinding] {
        guard let value else { return [] }
        if let s = value.stringValue { return HotkeyBinding(s).map { [$0] } ?? [] }
        guard let items = value.arrayValue else { return [] }
        return items.compactMap { item in
            if let s = item.stringValue { return HotkeyBinding(s) }
            if let seq = item.arrayValue {
                let strokes = seq.compactMap { $0.stringValue.flatMap(Keystroke.init) }
                return strokes.isEmpty ? nil : HotkeyBinding(strokes)
            }
            return nil
        }
    }

    public static func configValue(for bindings: [HotkeyBinding]) -> ConfigValue {
        .array(bindings.map { b in
            b.strokes.count == 1 ? .string(b.strokes[0].description) : .array(b.strokes.map { .string($0.description) })
        })
    }
}
