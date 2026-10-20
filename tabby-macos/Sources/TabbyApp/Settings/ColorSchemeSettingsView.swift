#if canImport(AppKit)
import SwiftUI
import TabbyCore

/// Scheme mode plus dark and light scheme pickers with previews (Tabby's
/// `ColorSchemeSettingsTabComponent`).
struct ColorSchemeSettingsView: View {
    @State private var filter = ""
    @State private var editingLight = false

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let config = services.config
        let all = services.schemes.all(custom: ColorSchemeCatalog.customSchemes(from: config))
        let currentDark = ColorScheme(config: config.value("terminal.colorScheme")) ?? .tabbyDefault
        let currentLight = ColorScheme(config: config.value("terminal.lightColorScheme")) ?? .tabbyDefaultLight
        let selected = editingLight ? currentLight : currentDark
        let shown = FuzzyMatcher.filter(all, query: filter) { $0.name }
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: ConfigBinding.string("appearance.colorSchemeMode")) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("Follow system").tag("auto")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)
            Picker("Editing", selection: $editingLight) {
                Text("Dark scheme: \(currentDark.name)").tag(false)
                Text("Light scheme: \(currentLight.name)").tag(true)
            }
            .pickerStyle(.radioGroup)
            SchemePreview(scheme: selected)
            TextField("Filter \(all.count) schemes", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(shown, id: \.name) { scheme in
                        SchemeTile(scheme: scheme, isSelected: scheme.name == selected.name)
                            .onTapGesture {
                                var value = scheme.configValue
                                value[ConfigValue.nonStructuralKey] = nil
                                config.set(editingLight ? "terminal.lightColorScheme" : "terminal.colorScheme", value)
                            }
                    }
                }
            }
        }
        .padding()
    }
}

struct SchemePreview: View {
    let scheme: ColorScheme

    var body: some View {
        let fg = scheme.foregroundRGB.color
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Text("user@host").foregroundStyle(scheme.paletteRGB[2].color)
                Text(":").foregroundStyle(fg)
                Text("~/projects").foregroundStyle(scheme.paletteRGB[4].color)
                Text("$ ls -la").foregroundStyle(fg)
            }
            HStack(spacing: 0) {
                Text("drwxr-xr-x ").foregroundStyle(fg)
                Text("src").foregroundStyle(scheme.paletteRGB[12].color)
                Text("  error: ").foregroundStyle(scheme.paletteRGB[1].color)
                Text("warning ").foregroundStyle(scheme.paletteRGB[3].color)
                Text("info").foregroundStyle(scheme.paletteRGB[6].color)
            }
            HStack(spacing: 2) {
                ForEach(0..<16, id: \.self) { i in
                    Rectangle().fill(scheme.paletteRGB[i].color).frame(width: 22, height: 14)
                }
            }
        }
        .font(.system(.body, design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(scheme.backgroundRGB.color, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SchemeTile: View {
    let scheme: ColorScheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scheme.name).font(.caption).foregroundStyle(scheme.foregroundRGB.color).lineLimit(1)
            HStack(spacing: 1) {
                ForEach(0..<8, id: \.self) { i in
                    Rectangle().fill(scheme.paletteRGB[i].color).frame(height: 10)
                }
            }
        }
        .padding(8)
        .background(scheme.backgroundRGB.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1))
        .contentShape(Rectangle())
    }
}
#endif
