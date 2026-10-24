#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Colour scheme page (Tabby's `ColorSchemeSettingsTabComponent`, phase 2 design): a card per
/// appearance with a live preview, a filterable grid of every scheme, and an editor for the
/// background, foreground, cursor, selection and the 16 ANSI colours.
struct ColorSchemeSettingsView: View {
    @State private var filter = ""
    @State private var editingLight = false
    @Environment(\.chrome) private var chrome

    private static let darkKey = "terminal.colorScheme"
    private static let lightKey = "terminal.lightColorScheme"

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let config = services.config
        let all = services.schemes.all(custom: ColorSchemeCatalog.customSchemes(from: config))
        let dark = ColorScheme(config: config.value(Self.darkKey)) ?? .tabbyDefault
        let light = ColorScheme(config: config.value(Self.lightKey)) ?? .tabbyDefaultLight
        let current = editingLight ? light : dark
        let shown = FuzzyMatcher.filter(all, query: filter) { $0.name }
        let customNames = Set(ColorSchemeCatalog.customSchemes(from: config).map(\.name))
        SettingsPage(L("Color scheme")) {
            HStack(spacing: 14) {
                ModeCard(title: L("Dark appearance"), symbol: "moon", scheme: dark, isEditing: !editingLight) { editingLight = false }
                ModeCard(title: L("Light appearance"), symbol: "sun.max", scheme: light, isEditing: editingLight) { editingLight = true }
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Schemes")).font(ChromeFont.headline).fixedSize()
                    Text(editingLight ? L("for the light appearance") : L("for the dark appearance")).foregroundStyle(chrome.textMuted.color)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
                        TextField(L("Filter {allCount} schemes", ["allCount": all.count]), text: $filter).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    // Narrows before the page gets wider than the window.
                    .frame(minWidth: 120, maxWidth: 220, minHeight: 26, maxHeight: 26)
                    .background(RoundedRectangle(cornerRadius: 6).fill(chrome.fill.color))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(shown, id: \.name) { scheme in
                        let custom = customNames.contains(scheme.name)
                        SchemeTile(scheme: scheme, isSelected: scheme.name == current.name, isCustom: custom)
                            .onTapGesture { select(scheme) }
                            .contextMenu {
                                if custom {
                                    Button(L("Rename…")) { rename(scheme.name) }
                                    Button(L("Delete…"), role: .destructive) { delete(scheme.name) }
                                }
                            }
                    }
                }
            }
            CustomSchemeEditor(scheme: current, original: all.first { $0.name == current.name }, write: write, saveAs: saveAs)
            SettingsGroup(L("Palette")) {
                SettingsRow(L("Generate 256-color palette"), subtitle: L("Generate extended 256-color palette from your base 16 colors"),
                            isOn: ConfigBinding.bool("terminal.paletteGenerate"))
                if config.bool("terminal.paletteGenerate") {
                    SettingsRow(L("Harmonious palette"),
                                subtitle: L("Whether to invert generated light theme colors. This helps give the 256-color palette more semantic meaning."),
                                isOn: ConfigBinding.bool("terminal.paletteHarmonious"))
                }
            }
        }
    }

    private func rename(_ name: String) {
        Prompts.text(in: NSApp.keyWindow, title: L("Rename color scheme"), value: name, confirm: L("Rename")) { new, _ in
            guard let new else { return }
            ColorSchemeCatalog.renameCustom(name, to: new, in: AppServices.shared.config)
        }
    }

    private func delete(_ name: String) {
        Prompts.confirm(in: NSApp.keyWindow, title: L("Delete “{name}”?", ["name": name]),
                        message: L("Profiles and appearances that use it keep its colours."), confirm: L("Delete"), destructive: true) { ok in
            if ok { ColorSchemeCatalog.deleteCustom(name, in: AppServices.shared.config) }
        }
    }

    private var key: String { editingLight ? Self.lightKey : Self.darkKey }

    private func select(_ scheme: ColorScheme) { write(scheme) }

    private func write(_ scheme: ColorScheme) {
        var value = scheme.configValue
        value[ConfigValue.nonStructuralKey] = nil
        AppServices.shared.config.set(key, value)
    }

    /// Adds the scheme to `terminal.customColorSchemes` under a new name and selects it.
    private func saveAs(_ scheme: ColorScheme) {
        Prompts.text(in: NSApp.keyWindow, title: L("Save colour scheme as"), value: L("{name} (custom)", ["name": scheme.name]), confirm: L("Save")) { name, _ in
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            let config = AppServices.shared.config
            var custom = (config.value("terminal.customColorSchemes")?.arrayValue ?? []).filter { $0["name"]?.stringValue != name }
            var copy = scheme
            copy.name = name
            custom.append(copy.configValue)
            config.set("terminal.customColorSchemes", .array(custom))
            write(copy)
        }
    }
}

/// One appearance: icon, title, the scheme name and a small live terminal.
private struct ModeCard: View {
    let title: String
    let symbol: String
    let scheme: ColorScheme
    let isEditing: Bool
    let select: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(chrome.textMuted.color)
                    Text(title).font(ChromeFont.bodyEmphasised)
                    Spacer()
                    Text(scheme.name).foregroundStyle(chrome.textMuted.color).lineLimit(1)
                }
                SchemePreview(scheme: scheme)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isEditing ? chrome.accent.color : chrome.border.color, lineWidth: isEditing ? 2 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isEditing ? L("The scheme grid and editor change this appearance") : L("Edit this appearance"))
    }
}

struct SchemePreview: View {
    let scheme: ColorScheme

    var body: some View {
        let fg = scheme.foregroundRGB.color
        let p = scheme.paletteRGB
        VStack(alignment: .leading, spacing: 3) {
            (Text("alex@mbp").foregroundColor(p[2].color).bold() + Text(" ~/Projects").foregroundColor(p[4].color) // l10n-ignore: sample terminal output
                + Text(" % swift build").foregroundColor(fg)) // l10n-ignore: sample terminal output
            (Text("error:").foregroundColor(p[1].color).bold() + Text(" missing return in closure").foregroundColor(fg)) // l10n-ignore: sample terminal output
            (Text("warning:").foregroundColor(p[3].color) + Text(" unused variable ").foregroundColor(fg) + Text("x").foregroundColor(p[6].color)) // l10n-ignore: sample terminal output
            HStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(p[i].color).frame(width: 14, height: 8) }
            }
            .padding(.top, 2)
        }
        .font(.custom("Menlo", size: 11))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme.backgroundRGB.color, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A scheme in the grid: its background with "Aa", six ANSI dots and the name.
struct SchemeTile: View {
    let scheme: ColorScheme
    let isSelected: Bool
    var isCustom = false
    @Environment(\.chrome) private var chrome
    @State private var hovering = false

    var body: some View {
        let p = scheme.paletteRGB
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Aa").font(.system(size: 13, weight: .semibold)).foregroundStyle(scheme.foregroundRGB.color) // l10n-ignore: sample terminal output
                Spacer()
                HStack(spacing: 3) {
                    ForEach([1, 2, 3, 4, 5, 6], id: \.self) { i in Circle().fill(p[i].color).frame(width: 7, height: 7) }
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(scheme.backgroundRGB.color, in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Text(scheme.name).font(ChromeFont.caption).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                if isCustom {
                    Text(L("Custom")).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 4).frame(height: 14)
                        .foregroundStyle(chrome.accent.color).background(Capsule().fill(chrome.accentFill.color)).fixedSize()
                }
                if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(chrome.accent.color).font(.system(size: 11)) }
            }
            .padding(.horizontal, 2)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? chrome.fill.color : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? chrome.accent.color : chrome.border.color, lineWidth: isSelected ? 2 : 0.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(scheme.name)
    }
}

/// Colour wells for the scheme of the appearance being edited. Edits go straight into the
/// selected scheme, as Tabby's editor does; Reset brings back the named scheme and Save as…
/// keeps the result as a custom scheme.
private struct CustomSchemeEditor: View {
    let scheme: ColorScheme
    let original: ColorScheme?
    let write: (ColorScheme) -> Void
    let saveAs: (ColorScheme) -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        let edited = original.map { $0 != scheme } ?? true
        SettingsGroup(edited ? L("Custom scheme · “{name} (edited)”", ["name": scheme.name]) : L("Edit “{name}”", ["name": scheme.name])) {
            // In a narrow window the buttons go under the wells and the palette into four rows,
            // so the page never gets wider than the window.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) {
                    wells
                    Spacer()
                    buttons(edited: edited)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) { mainWells }
                    HStack(spacing: 18) { textWells }
                    HStack(spacing: 8) { buttons(edited: edited) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            ViewThatFits(in: .horizontal) {
                palette(columns: 8)
                palette(columns: 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    @ViewBuilder private var wells: some View {
        mainWells
        textWells
    }

    @ViewBuilder private var mainWells: some View {
        well(L("Background"), \.background)
        well(L("Foreground"), \.foreground)
        well(L("Cursor"), \.cursor)
    }

    /// Tabby's cursor accent and selection colours.
    @ViewBuilder private var textWells: some View {
        well(L("Cursor text"), Binding(get: { scheme.cursorAccent ?? scheme.background }, set: { var s = scheme; s.cursorAccent = $0; write(s) }))
            .help(L("Block cursor foreground"))
        well(L("Selection"), Binding(get: { scheme.selection ?? "#80808066" }, set: { var s = scheme; s.selection = $0; write(s) }))
        well(L("Selection text"), Binding(get: { scheme.selectionForeground ?? scheme.foreground }, set: { var s = scheme; s.selectionForeground = $0; write(s) }))
            .help(L("Selection foreground"))
    }

    @ViewBuilder private func buttons(edited: Bool) -> some View {
        Button(L("Reset")) { if let original { write(original) } }.buttonStyle(ChromeButtonStyle()).disabled(!edited || original == nil)
        Button(L("Save as…")) { saveAs(scheme) }.buttonStyle(ChromeButtonStyle()).fixedSize()
    }

    /// The 16 ANSI colours, `columns` to a row (8: normal and bright on a row each).
    private func palette(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stride(from: 0, to: 16, by: columns)), id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row..<(row + columns), id: \.self) { i in
                        VStack(spacing: 3) {
                            ColorPicker("", selection: color(index: i), supportsOpacity: false).labelsHidden()
                            Text("\(i)").font(.custom("Menlo", size: 10)).foregroundStyle(chrome.textFaint.color)
                        }
                    }
                }
            }
        }
    }

    private func well(_ label: String, _ path: WritableKeyPath<ColorScheme, String>) -> some View {
        well(label, Binding(get: { scheme[keyPath: path] }, set: { var s = scheme; s[keyPath: path] = $0; write(s) }))
    }

    private func well(_ label: String, _ hex: Binding<String>) -> some View {
        VStack(spacing: 3) {
            ColorPicker("", selection: Binding(get: { (RGBColor(hex: hex.wrappedValue) ?? .black).color },
                                               set: { hex.wrappedValue = Self.hex($0) }), supportsOpacity: false)
                .labelsHidden()
            Text(label).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).fixedSize()
        }
    }

    private func color(index i: Int) -> Binding<Color> {
        Binding(get: { (RGBColor(hex: scheme.colors[i]) ?? .black).color },
                set: { var s = scheme; s.colors[i] = Self.hex($0); write(s) })
    }

    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return RGBColor(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent)).hex
    }
}
#endif
