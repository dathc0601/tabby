#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
import TabbyCore

/// Converts between AppKit key events, Tabby keystrokes and menu key equivalents.
enum KeyMapping {
    /// Virtual key codes for keys whose names don't come from characters.
    static let specialKeys: [Int: String] = [
        kVK_LeftArrow: "Left", kVK_RightArrow: "Right", kVK_UpArrow: "Up", kVK_DownArrow: "Down",
        kVK_Return: "Enter", kVK_ANSI_KeypadEnter: "Enter", kVK_Tab: "Tab", kVK_Space: "Space",
        kVK_Delete: "Backspace", kVK_ForwardDelete: "Delete", kVK_Escape: "Escape",
        kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PageUp", kVK_PageDown: "PageDown",
        kVK_Help: "Insert",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17",
        kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    /// US-layout codes, used for punctuation (Tabby uses `event.code` for these too).
    static let codeKeys: [Int: String] = [
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
    ]

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> Keystroke.Modifiers {
        var m: Keystroke.Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.option) { m.insert(.option) }
        if flags.contains(.shift) { m.insert(.shift) }
        return m
    }

    static func keystroke(for event: NSEvent) -> Keystroke? {
        guard event.type == .keyDown else { return nil }
        let mods = modifiers(event.modifierFlags)
        let code = Int(event.keyCode)
        if let name = specialKeys[code] { return Keystroke(modifiers: mods, key: name) }
        if let name = codeKeys[code] { return Keystroke(modifiers: mods, key: name) }
        // Letters follow the active layout (like Tabby's handling of Dvorak etc.).
        if let chars = event.characters(byApplyingModifiers: []), let first = chars.first, first.isLetter {
            return Keystroke(modifiers: mods, key: String(first).uppercased())
        }
        if let chars = event.charactersIgnoringModifiers, let first = chars.first {
            return Keystroke(modifiers: mods, key: String(first))
        }
        return nil
    }

    /// Menu key equivalent for a single-stroke binding, if it can be expressed.
    static func keyEquivalent(for stroke: Keystroke) -> (String, NSEvent.ModifierFlags)? {
        guard let key = stroke.key else { return nil }
        var flags: NSEvent.ModifierFlags = []
        if stroke.modifiers.contains(.control) { flags.insert(.control) }
        if stroke.modifiers.contains(.command) { flags.insert(.command) }
        if stroke.modifiers.contains(.option) { flags.insert(.option) }
        if stroke.modifiers.contains(.shift) { flags.insert(.shift) }
        let equivalent: String
        switch key {
        case "Left": equivalent = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "Right": equivalent = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "Up": equivalent = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "Down": equivalent = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "Enter": equivalent = "\r"
        case "Tab": equivalent = "\t"
        case "Space": equivalent = " "
        case "Backspace": equivalent = String(UnicodeScalar(8))
        case "Delete": equivalent = String(UnicodeScalar(NSDeleteFunctionKey)!)
        case "Escape": equivalent = String(UnicodeScalar(27))
        case "Home": equivalent = String(UnicodeScalar(NSHomeFunctionKey)!)
        case "End": equivalent = String(UnicodeScalar(NSEndFunctionKey)!)
        case "PageUp": equivalent = String(UnicodeScalar(NSPageUpFunctionKey)!)
        case "PageDown": equivalent = String(UnicodeScalar(NSPageDownFunctionKey)!)
        default:
            guard key.count == 1 else { return nil }
            equivalent = key.lowercased()
        }
        return (equivalent, flags)
    }

    /// Carbon key code + modifiers for the global hotkey.
    static func carbonHotKey(for stroke: Keystroke) -> (UInt32, UInt32)? {
        guard let key = stroke.key else { return nil }
        var code: Int? = key == "Enter" ? kVK_Return : nil
        if code == nil, let c = specialKeys.first(where: { $0.value == key })?.key { code = c }
        if code == nil, let c = codeKeys.first(where: { $0.value == key })?.key { code = c }
        if code == nil, key.count == 1, let letter = letterCodes[key.uppercased()] { code = letter }
        guard let code else { return nil }
        var mods: UInt32 = 0
        if stroke.modifiers.contains(.command) { mods |= UInt32(cmdKey) }
        if stroke.modifiers.contains(.control) { mods |= UInt32(controlKey) }
        if stroke.modifiers.contains(.option) { mods |= UInt32(optionKey) }
        if stroke.modifiers.contains(.shift) { mods |= UInt32(shiftKey) }
        return (UInt32(code), mods)
    }

    static let letterCodes: [String: Int] = [
        "A": kVK_ANSI_A, "B": kVK_ANSI_B, "C": kVK_ANSI_C, "D": kVK_ANSI_D, "E": kVK_ANSI_E, "F": kVK_ANSI_F,
        "G": kVK_ANSI_G, "H": kVK_ANSI_H, "I": kVK_ANSI_I, "J": kVK_ANSI_J, "K": kVK_ANSI_K, "L": kVK_ANSI_L,
        "M": kVK_ANSI_M, "N": kVK_ANSI_N, "O": kVK_ANSI_O, "P": kVK_ANSI_P, "Q": kVK_ANSI_Q, "R": kVK_ANSI_R,
        "S": kVK_ANSI_S, "T": kVK_ANSI_T, "U": kVK_ANSI_U, "V": kVK_ANSI_V, "W": kVK_ANSI_W, "X": kVK_ANSI_X,
        "Y": kVK_ANSI_Y, "Z": kVK_ANSI_Z,
    ]
}
#endif
