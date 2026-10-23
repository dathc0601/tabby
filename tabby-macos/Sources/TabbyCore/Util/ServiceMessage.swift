import Foundation

/// The lines a connection writes into its own terminal: an inverse badge naming the
/// connection type, then the text (Tabby's `emitServiceMessage` in each plugin's tab), and
/// the red ` X ` error line.
public enum ServiceMessage {
    public enum Badge: Sendable {
        case ssh, serial, telnet

        var label: String {
            switch self {
            case .ssh: return " SSH "
            case .serial: return " Serial "
            case .telnet: return " Telnet "
            }
        }

        /// SGR background: Tabby draws SSH on cyan and the others on white.
        var background: Int { self == .ssh ? 46 : 47 }
    }

    /// One service line; continuation lines are indented to start after the badge.
    public static func line(_ text: String, badge: Badge) -> Data {
        let indent = String(repeating: " ", count: badge.label.count + 1)
        let body = text.replacingOccurrences(of: "\n", with: "\r\n" + indent)
        return Data("\u{1b}[0;30;\(badge.background)m\(badge.label)\u{1b}[0m \(body)\r\n".utf8)
    }

    public static func error(_ text: String) -> Data {
        Data("\u{1b}[0;37;41m X \u{1b}[0m \u{1b}[31m\(text)\u{1b}[0m\r\n".utf8)
    }
}
