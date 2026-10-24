#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbyCLIKit

/// The rows of Tabby's environment editor (`environmentEditor.component.ts`): name = value
/// pairs that become `options.env`.
struct EnvironmentRows: Equatable {
    struct Row: Equatable, Identifiable {
        let id = UUID()
        var name: String
        var value: String
    }

    var rows: [Row]

    init(env: ConfigValue?) {
        rows = (env?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { Row(name: $0.key, value: $0.value.stringValue ?? "") }
    }

    /// The variables to save; rows without a name are left out, and no variables means no key.
    var env: ConfigValue? {
        var o: [String: ConfigValue] = [:]
        for row in rows where !row.name.trimmingCharacters(in: .whitespaces).isEmpty {
            o[row.name.trimmingCharacters(in: .whitespaces)] = .string(row.value)
        }
        return o.isEmpty ? Optional<ConfigValue>.none : .object(o)
    }

    mutating func add() { rows.append(Row(name: "", value: "")) }
    mutating func remove(at index: Int) { rows.remove(at: index) }

    /// Tabby shows its "extend PATH" example while there is no PATH variable.
    var showsExample: Bool { !rows.contains { $0.name.lowercased() == "path" } }
    mutating func addExample() { rows.append(Row(name: "PATH", value: "/opt/custom:$PATH")) } // l10n-ignore: shell variable
}

/// Tabby's environment editor for local profiles.
struct EnvironmentEditor: View {
    @Binding var env: ConfigValue?
    @State private var model: EnvironmentRows
    @Environment(\.chrome) private var chrome

    init(env: Binding<ConfigValue?>) {
        _env = env
        _model = State(initialValue: EnvironmentRows(env: env.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, _ in
                HStack(spacing: 6) {
                    TextField(L("Variable name"), text: $model.rows[index].name).frame(width: 150)
                    Text(verbatim: "=").foregroundStyle(chrome.textMuted.color)
                    TextField(L("Value"), text: $model.rows[index].value)
                    IconButton(symbol: "trash", help: L("Remove"), size: 22) { model.remove(at: index) }
                }
                .textFieldStyle(.roundedBorder)
                .font(.custom("Menlo", size: 12))
            }
            HStack(spacing: 6) {
                Button { model.add() } label: { Label(L("Add"), systemImage: "plus") }.buttonStyle(ChromeButtonStyle())
                Spacer()
                Text(L("Substitutions allowed.")).foregroundStyle(chrome.textMuted.color)
                if model.showsExample {
                    Text(L("Example:")).foregroundStyle(chrome.textMuted.color)
                    Button(L("extend PATH")) { model.addExample() }.buttonStyle(.link)
                }
            }
            .font(ChromeFont.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .onChange(of: model) { _, new in env = new.env }
    }
}

/// One line for a local profile's command and arguments, split with shell quoting (Tabby's
/// command-line editor; Tabby splits with shell-quote too).
enum CommandLineField {
    static func split(_ line: String) -> (command: String, args: [String]) {
        let words = ShellWords.split(line)
        return (words.first ?? "", Array(words.dropFirst()))
    }

    static func join(command: String, args: [String]) -> String {
        ([command] + args).filter { !$0.isEmpty }.map(ShellWords.quote).joined(separator: " ")
    }
}
#endif
