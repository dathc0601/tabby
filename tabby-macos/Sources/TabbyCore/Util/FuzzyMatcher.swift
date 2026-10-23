import Foundation

/// Subsequence fuzzy matching with a simple score, used by the selector / command palette.
public enum FuzzyMatcher {
    /// Returns a score (higher is better) or nil when `query` is not a subsequence of `text`.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        if q.isEmpty { return 0 }
        let t = Array(text.lowercased())
        var qi = 0
        var score = 0
        var lastMatch = -2
        var firstMatch = -1
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            if firstMatch < 0 { firstMatch = ti }
            score += 10
            if ti == lastMatch + 1 { score += 15 }               // consecutive
            if ti == 0 || !t[ti - 1].isLetter { score += 20 }    // word start
            lastMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        score -= max(0, firstMatch)
        score -= max(0, t.count - q.count) / 4
        if text.lowercased().contains(query.lowercased()) { score += 50 }
        return score
    }

    /// Filters and sorts items by score, keeping the original order for ties.
    public static func filter<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return items }
        return items.enumerated()
            .compactMap { pair -> (Int, Int, T)? in
                guard let s = score(query, in: text(pair.element)) else { return nil }
                return (s, pair.offset, pair.element)
            }
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
            .map { $0.2 }
    }
}
