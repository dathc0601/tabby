import Foundation

/// Minimal port of the `slugify` npm package as Tabby uses it for profile ids:
/// spaces become `-`, symbols outside `[A-Za-z0-9-._~]` are dropped, case is kept.
public enum Slug {
    public static func make(_ input: String) -> String {
        let folded = input.applyingTransform(.stripDiacritics, reverse: false) ?? input
        var out = ""
        var lastWasDash = false
        for scalar in folded.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\n" {
                if !lastWasDash && !out.isEmpty { out.append("-"); lastWasDash = true }
                continue
            }
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || "-._~".unicodeScalars.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
