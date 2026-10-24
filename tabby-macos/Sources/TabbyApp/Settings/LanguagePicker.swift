#if canImport(AppKit)
import SwiftUI
import TabbyCore

/// The `language` menu (Settings › Application and the Welcome tab): "Automatic" (null), then
/// every language in its own name, as Tabby's settings page lists them.
struct LanguagePicker: View {
    static var options: [(tag: String, name: String)] {
        [("", L("Automatic"))] + Languages.all.map { ($0.code, $0.name) }
    }

    var body: some View {
        RowPicker(selection: ConfigBinding.optionalString("language")) {
            ForEach(Self.options, id: \.tag) { option in
                Text(verbatim: option.name).tag(option.tag)
            }
        }
    }
}
extension View {
    /// Rebuilds the view when the language changes. SwiftUI only redraws views that read
    /// observed state, so a view whose text comes from `L()` alone (the settings sidebar, a
    /// tab's title) kept the old language after a live switch (M10).
    func redrawnOnLanguageChange() -> some View { modifier(LanguageIdentity()) }
}

private struct LanguageIdentity: ViewModifier {
    func body(content: Content) -> some View {
        content.id(AppServices.shared.language ?? "")
    }
}
#endif
