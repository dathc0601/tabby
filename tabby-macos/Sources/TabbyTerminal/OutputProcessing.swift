import Foundation
import TabbyCore

/// Detects percentages in output for the tab progress bar
/// (`BaseTerminalTabComponent` in `tabby-terminal/src/api/baseTerminalTab.component.ts`).
public struct ProgressDetector {
    private static let regex = try! NSRegularExpression(pattern: #"(^|[^\d])(\d+(\.\d+)?)%([^\d]|$)"#)

    public init() {}

    /// Returns a percentage in 1...100 if the chunk contains one.
    public func detect(in text: String) -> Double? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = Self.regex.firstMatch(in: text, range: range),
              let r = Range(m.range(at: 2), in: text),
              let value = Double(text[r]) else { return nil }
        return value > 0 && value <= 100 ? value : nil
    }
}

/// Runs a profile's login scripts: when `expect` appears in the output, send `send` + newline.
/// Port of `LoginScriptProcessor` (`tabby-terminal/src/middleware/loginScriptProcessing.ts`).
public final class LoginScriptRunner {
    public struct Script: Equatable {
        public var expect: String
        public var send: String
        public var isRegex: Bool
        public var optional: Bool
    }

    private var remaining: [Script]

    public init(scripts: [LoginScript]) {
        remaining = scripts.map {
            Script(expect: $0.isRegex ? $0.expect : Self.unescape($0.expect), send: Self.unescape($0.send),
                   isRegex: $0.isRegex, optional: $0.optional)
        }
    }

    public var isDone: Bool { remaining.isEmpty }

    /// Feeds output; returns the data to send back to the session, if any.
    public func process(_ text: String) -> [String] {
        var toSend: [String] = []
        var index = 0
        while index < remaining.count {
            let script = remaining[index]
            if script.expect.isEmpty { index += 1; continue }
            let matched: Bool
            if script.isRegex {
                matched = (try? NSRegularExpression(pattern: script.expect))?
                    .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            } else {
                matched = text.contains(script.expect)
            }
            if matched {
                toSend.append(script.send + "\n")
                remaining.remove(at: index)
            } else if script.optional {
                remaining.remove(at: index)
            } else {
                break
            }
        }
        return toSend
    }

    /// Scripts without `expect` run as soon as the session starts.
    public func unconditionalScripts() -> [String] {
        let unconditional = remaining.filter { $0.expect.isEmpty }
        remaining.removeAll { $0.expect.isEmpty }
        return unconditional.map { $0.send + "\n" }
    }

    static func unescape(_ s: String) -> String {
        let map: [Character: String] = ["a": "\u{07}", "b": "\u{08}", "e": "\u{1b}", "f": "\u{0c}",
                                        "n": "\n", "r": "\r", "t": "\t", "v": "\u{0b}"]
        var out = ""
        var escaping = false
        for ch in s {
            if escaping {
                out += map[ch] ?? String(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else {
                out.append(ch)
            }
        }
        if escaping { out.append("\\") }
        return out
    }
}

/// Paste preprocessing (`tabby-terminal` paste handling): trimming, newline replacement and
/// the "paste multiple lines?" decision.
public enum PastePreparation {
    public static func prepare(_ text: String, trimWhitespace: Bool, replaceNewlinesWithSpaces: Bool) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if trimWhitespace {
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if replaceNewlinesWithSpaces {
            t = t.replacingOccurrences(of: "\r", with: " ")
        }
        return t
    }

    public static func needsMultilineWarning(_ text: String, enabled: Bool, alternateScreen: Bool) -> Bool {
        enabled && !alternateScreen && text.contains("\r")
    }

    public static func bracketed(_ text: String, enabled: Bool) -> String {
        enabled ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
    }
}
