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
#endif
