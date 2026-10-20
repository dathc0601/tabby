#if canImport(AppKit)
import SwiftUI
import Observation
import TabbyTerminal

/// State for the terminal search bar (Tabby's `SearchPanelComponent`).
@MainActor
@Observable
final class SearchModel {
    var query = ""
    var caseSensitive = false
    var regex = false
    var wholeWord = false
    var index = 0
    var total = 0
    @ObservationIgnored private weak var engine: TerminalEngine?

    init(engine: TerminalEngine) {
        self.engine = engine
        let opts = AppServices.shared.config.value("terminal.searchOptions")
        caseSensitive = opts?["caseSensitive"]?.boolValue ?? false
        regex = opts?["regex"]?.boolValue ?? false
        wholeWord = opts?["wholeWord"]?.boolValue ?? false
    }

    var options: TerminalSearchOptions {
        TerminalSearchOptions(caseSensitive: caseSensitive, regex: regex, wholeWord: wholeWord)
    }

    func find(backwards: Bool = false) {
        guard let engine, !query.isEmpty else { total = 0; index = 0; return }
        _ = engine.find(query, options: options, backwards: backwards)
        let summary = engine.searchSummary(query, options: options)
        index = summary.index
        total = summary.total
    }

    func optionsChanged() {
        let config = AppServices.shared.config
        config.set("terminal.searchOptions", ["caseSensitive": .bool(caseSensitive), "regex": .bool(regex), "wholeWord": .bool(wholeWord)])
        find()
    }
}

struct SearchBarView: View {
    @State var model: SearchModel
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let chrome = AppServices.shared.theme.chrome
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.find() }
                .onChange(of: model.query) { model.find() }
                .onKeyPress(.upArrow) { model.find(backwards: true); return .handled }
                .onKeyPress(.downArrow) { model.find(); return .handled }
                .onExitCommand { onClose() }
            Text(model.total == 0 ? (model.query.isEmpty ? "" : "No results") : "\(model.index) / \(model.total)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(chrome.textMuted.color)
                .frame(minWidth: 54, alignment: .trailing)
            Button { model.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match")
            Button { model.find() } label: { Image(systemName: "chevron.down") }
                .help("Next match")
            Toggle(isOn: $model.caseSensitive) { Text("Aa") }
                .toggleStyle(.button).help("Case sensitive")
                .onChange(of: model.caseSensitive) { model.optionsChanged() }
            Toggle(isOn: $model.regex) { Text(".*") }
                .toggleStyle(.button).help("Regular expression")
                .onChange(of: model.regex) { model.optionsChanged() }
            Toggle(isOn: $model.wholeWord) { Text("W") }
                .toggleStyle(.button).help("Whole word")
                .onChange(of: model.wholeWord) { model.optionsChanged() }
            Button(action: onClose) { Image(systemName: "xmark") }
                .help("Close search")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chrome.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(chrome.border.color))
        .foregroundStyle(chrome.text.color)
        .onAppear { focused = true }
    }
}
#endif
