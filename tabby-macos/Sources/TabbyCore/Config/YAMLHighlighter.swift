import Foundation

/// Line-based YAML tokens for the Config file editor's syntax colours. It only has to look
/// right for config.yaml (block mappings, lists, scalars, comments), not parse YAML.
public enum YAMLHighlighter {
    public enum Kind: String, Sendable {
        case key, string, number, bool, comment
    }

    public struct Token: Equatable, Sendable {
        /// UTF-16 offsets, so NSTextView can use them as NSRanges.
        public var range: Range<Int>
        public var kind: Kind
    }

    private static let space = UInt16(UInt8(ascii: " "))
    private static let hash = UInt16(UInt8(ascii: "#"))
    private static let dash = UInt16(UInt8(ascii: "-"))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let quotes: Set<UInt16> = [UInt16(UInt8(ascii: "\"")), UInt16(UInt8(ascii: "'"))]
    private static let keywords: Set<String> = ["true", "false", "null", "~", "yes", "no", "on", "off"]

    public static func tokens(in line: String) -> [Token] {
        tokens(Array(line.utf16), offset: 0)
    }

    public static func tokens(inDocument text: String) -> [Token] {
        let u = Array(text.utf16)
        var result: [Token] = []
        var start = 0
        for (i, c) in u.enumerated() where c == 10 {
            result += tokens(Array(u[start..<i]), offset: start)
            start = i + 1
        }
        if start < u.count { result += tokens(Array(u[start...]), offset: start) }
        return result
    }

    private static func tokens(_ u: [UInt16], offset: Int) -> [Token] {
        var i = 0
        func skipSpaces() { while i < u.count && u[i] == space { i += 1 } }
        skipSpaces()
        guard i < u.count else { return [] }
        func token(_ r: Range<Int>, _ kind: Kind) -> Token { Token(range: (r.lowerBound + offset)..<(r.upperBound + offset), kind: kind) }
        if u[i] == hash { return [token(i..<u.count, .comment)] }
        if u[i] == dash && (i + 1 == u.count || u[i + 1] == space) {
            i += 1
            skipSpaces()
        }

        // A comment starts at a `#` after a space, outside quotes.
        var commentStart: Int?
        var quote: UInt16?
        for j in i..<u.count {
            let c = u[j]
            if let q = quote {
                if c == q { quote = nil }
            } else if quotes.contains(c) {
                quote = c
            } else if c == hash && j > 0 && u[j - 1] == space {
                commentStart = j
                break
            }
        }
        var end = commentStart ?? u.count
        while end > i && u[end - 1] == space { end -= 1 }

        var result: [Token] = []
        var valueStart = i
        quote = nil
        for j in i..<end {
            let c = u[j]
            if let q = quote {
                if c == q { quote = nil }
            } else if quotes.contains(c) {
                quote = c
            } else if c == colon && (j + 1 == end || u[j + 1] == space) {
                if j > i { result.append(token(i..<j, .key)) }
                valueStart = j + 1
                while valueStart < end && u[valueStart] == space { valueStart += 1 }
                break
            }
        }
        if valueStart < end {
            let text = String(decoding: u[valueStart..<end], as: UTF16.self)
            let kind: Kind = keywords.contains(text.lowercased()) ? .bool : (Double(text) != nil ? .number : .string)
            result.append(token(valueStart..<end, kind))
        }
        if let commentStart { result.append(token(commentStart..<u.count, .comment)) }
        return result
    }
}
