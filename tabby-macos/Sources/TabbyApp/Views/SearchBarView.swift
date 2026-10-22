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

    /// Re-runs the search from the top as the query changes (find-as-you-type).
    func restart() {
        engine?.clearSearch()
        find()
    }

    func find(backwards: Bool = false) {
        guard let engine, !query.isEmpty else { engine?.clearSearch(); total = 0; index = 0; return }
        _ = engine.find(query, options: options, backwards: backwards)
        let summary = engine.searchSummary(query, options: options)
        index = summary.index
        total = summary.total
    }

    func optionsChanged() {
        let config = AppServices.shared.config
        config.set("terminal.searchOptions", ["caseSensitive": .bool(caseSensitive), "regex": .bool(regex), "wholeWord": .bool(wholeWord)])
        restart()
    }
}

struct SearchBarView: View {
    @State var model: SearchModel
    var onClose: () -> Void

    var body: some View {
        SearchBarContent(model: model, onClose: onClose).chromeEnvironment()
    }
}

/// Docked at the top right of the pane (design: query, "n / m", case / regex / whole word,
/// previous / next, close).
private struct SearchBarContent: View {
    @Bindable var model: SearchModel
    var onClose: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color).padding(.leading, 4)
            TextField("Search", text: $model.query)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { model.find() }
                // ⇧↩ steps back, as in other macOS find bars; plain ↩ goes to `onSubmit`.
                .onKeyPress(.return, phases: [.down, .repeat]) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.find(backwards: true)
                    return .handled
                }
                .onChange(of: model.query) { model.restart() }
                .onKeyPress(.upArrow) { model.find(backwards: true); return .handled }
                .onKeyPress(.downArrow) { model.find(); return .handled }
                .onExitCommand { onClose() }
            Text(model.total == 0 ? (model.query.isEmpty ? "" : "No results") : "\(model.index) / \(model.total)")
                .font(ChromeFont.caption.monospacedDigit())
                .foregroundStyle(chrome.textMuted.color)
                .frame(minWidth: 58, alignment: .trailing)
                .padding(.trailing, 4)
            toggle("textformat", "Match case", $model.caseSensitive)
            toggle("asterisk", "Regular expression", $model.regex)
            toggle("textformat.abc", "Whole word", $model.wholeWord)
            Rectangle().fill(chrome.separator.color).frame(width: 1, height: 16).padding(.horizontal, 2)
            IconButton(symbol: "chevron.up", help: "Previous match (⇧↩)", size: 24) { model.find(backwards: true) }
            IconButton(symbol: "chevron.down", help: "Next match (↩)", size: 24) { model.find() }
            IconButton(symbol: "xmark", help: "Close search (esc)", size: 24, action: onClose)
        }
        .font(ChromeFont.body)
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(chrome.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(chrome.border.color, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .foregroundStyle(chrome.text.color)
        .onAppear { focused = true }
    }

    private func toggle(_ symbol: String, _ help: String, _ isOn: Binding<Bool>) -> some View {
        IconButton(symbol: symbol, help: help, isActive: isOn.wrappedValue, size: 24) {
            isOn.wrappedValue.toggle()
            model.optionsChanged()
        }
    }
}
#endif
