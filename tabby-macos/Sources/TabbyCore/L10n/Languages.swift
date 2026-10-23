import Foundation

public struct Language: Hashable, Sendable, Identifiable {
    public let code: String
    /// The language's own name, shown as is in every language.
    public let name: String
    public var id: String { code }
}

/// Tabby's languages (`tabby-core/src/services/locale.service.ts`), in Tabby's order, plus
/// Vietnamese (phase 5) among the Latin-script ones.
public enum Languages {
    public static let all: [Language] = [
        ("af-ZA", "Afrikaans"), ("id-ID", "Bahasa Indonesia"), ("cs-CZ", "Čeština"), ("da-DK", "Dansk"),
        ("de-DE", "Deutsch"), ("en-GB", "English (UK)"), ("en-US", "English (US)"), ("es-ES", "Español"),
        ("fr-FR", "Français"), ("hr-HR", "Hrvatski"), ("it-IT", "Italiano"), ("pl-PL", "Polski"),
        ("pt-PT", "Português"), ("pt-BR", "Português do Brasil"), ("sv-SE", "Svenska"), ("tr-TR", "Türkçe"),
        ("vi-VN", "Tiếng Việt"), ("bg-BG", "Български"), ("ru-RU", "Русский"), ("sr-SP", "Српски"),
        ("uk-UA", "Українська"), ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("zh-CN", "中文（简体）"),
        ("zh-TW", "中文 (繁體)"),
    ].map { Language(code: $0.0, name: $0.1) }

    /// The language to show: the configured one when it is known; otherwise the first of the
    /// system's preferred languages that matches a code exactly or by language (★ Tabby
    /// needs an exact match). `nil` means English without a catalog.
    public static func resolve(configured: String?, preferred: [String]) -> String? {
        if let configured, all.contains(where: { $0.code == configured }) { return configured }
        for language in preferred {
            if let code = match(language) { return code }
        }
        return nil
    }

    static func match(_ raw: String) -> String? {
        let tag = raw.replacingOccurrences(of: "_", with: "-")
        if let exact = all.first(where: { $0.code.caseInsensitiveCompare(tag) == .orderedSame }) { return exact.code }
        let parts = tag.lowercased().split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return nil }
        switch language {
        case "zh":
            if parts.contains("hans") { return "zh-CN" }
            if parts.contains(where: { ["hant", "tw", "hk", "mo"].contains($0) }) { return "zh-TW" }
            return "zh-CN"
        case "pt": return "pt-PT"
        case "en": return "en-US"
        default: return all.first { $0.code.lowercased().hasPrefix(language + "-") }?.code
        }
    }
}
