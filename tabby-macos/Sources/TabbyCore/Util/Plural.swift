import Foundation

/// English counts for UI text: "1 password", "2 passwords". Verbatim digits, so they are
/// never grouped by the locale.
public enum Plural {
    public static func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}
