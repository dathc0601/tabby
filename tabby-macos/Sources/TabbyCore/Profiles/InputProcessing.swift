import Foundation

/// Tabby's `InputProcessor` (`tabby-terminal/src/middleware/inputProcessing.ts`): what the
/// Backspace key sends, per profile (`options.input.backspace`).
public enum InputProcessing {
    /// A lone DEL keystroke becomes ^H (`ctrl-h`), ESC [3~ (`delete`), or stays DEL
    /// (`backspace`, `ctrl-?`); anything else is sent as typed.
    public static func translate(_ data: Data, backspace: String?) -> Data {
        guard data.count == 1, data.first == 0x7f else { return data }
        switch backspace {
        case "ctrl-h": return Data([0x08])
        case "delete": return Data("\u{1b}[3~".utf8)
        default: return data
        }
    }

    public static func backspaceMode(_ options: ConfigValue) -> String? {
        options["input"]?["backspace"]?.stringValue
    }
}
