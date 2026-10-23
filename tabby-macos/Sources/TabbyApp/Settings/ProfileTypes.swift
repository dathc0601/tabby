#if canImport(AppKit)
import Foundation
import TabbyCore
import TabbyTerminal

/// What the UI needs to know per profile type: its name, and how a new profile starts.
enum ProfileTypes {
    /// The types the Profiles page can create, in the New menu's order.
    static let creatable = ["local", "ssh", "serial", "telnet"]

    static func title(_ type: String) -> String {
        switch type {
        case "local": return "Local terminal"
        case "ssh": return "SSH connection"
        case "serial": return "Serial connection"
        case "telnet": return "Telnet connection"
        default: return type.capitalized
        }
    }

    /// The short label of the type badge in the profile list.
    static func badge(_ type: String) -> String {
        switch type {
        case "ssh": return "SSH"
        case "local": return "Local"
        case "split-layout": return "Layout"
        default: return type.capitalized
        }
    }

    static func newProfile(_ type: String) -> Profile {
        switch type {
        case "ssh": return Profile(type: "ssh", name: "", options: ["host": "", "port": 22, "user": .string(NSUserName())])
        // No port or rate: both are asked for when the tab opens, until the profile names them.
        case "serial": return Profile(type: "serial", name: "", options: [:])
        case "telnet": return Profile(type: "telnet", name: "", options: ["host": "", "port": 23])
        default: return Profile(type: "local", name: "New profile", options: LocalOptions(command: ShellDetector.loginShellName()).configValue)
        }
    }

    /// Providers the "Quick connect uses" setting can pick.
    static var quickConnectProviders: [ProfileProvider] {
        AppServices.shared.profiles.providers.filter(\.supportsQuickConnect)
    }
}

/// Tabby's names for the stream-processing modes (`streamProcessingSettings.component.ts`);
/// "" stands for its null ("Normal", "Keep").
enum StreamModeNames {
    struct Mode {
        let value: String
        let name: String
        var description = ""
    }

    static let inputModes = [
        Mode(value: "", name: "Normal", description: "Input is sent as you type"),
        Mode(value: "local-echo", name: "Local echo", description: "Immediately echoes your input locally"),
        Mode(value: "readline", name: "Line by line", description: "Line editor, input is sent after you press Enter"),
        Mode(value: "readline-hex", name: "Hexadecimal", description: "Send bytes by typing in hex values"),
    ]

    static let outputModes = [
        Mode(value: "", name: "Normal", description: "Output is shown as it is received"),
        Mode(value: "hex", name: "Hexadecimal", description: "Output is shown as a hexdump"),
    ]

    static let newlineModes = [
        Mode(value: "", name: "Keep"),
        Mode(value: "strip", name: "Strip"),
        Mode(value: "cr", name: "Force CR"),
        Mode(value: "lf", name: "Force LF"),
        Mode(value: "crlf", name: "Force CRLF"),
        Mode(value: "implicit_cr", name: "Implicit CR in every LF"),
        Mode(value: "implicit_lf", name: "Implicit LF in every CR"),
    ]

    static func inputDescription(_ value: String?) -> String {
        inputModes.first { $0.value == (value ?? "") }?.description ?? ""
    }

    static func outputDescription(_ value: String?) -> String {
        outputModes.first { $0.value == (value ?? "") }?.description ?? ""
    }
}
#endif
