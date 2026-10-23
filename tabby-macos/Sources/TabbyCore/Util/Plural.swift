import Foundation

/// English counts for UI text: "1 password", "2 passwords". Verbatim digits, so they are
/// never grouped by the locale.
public enum Plural {
    /// Phase 5: both forms are catalog keys, `{n}` is the count. ★ Only one/other forms, so
    /// languages with more plural forms use "other".
    public static func count(_ n: Int, one: String, other: String) -> String {
        L(n == 1 ? one : other, ["n": n])
    }

    public static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
