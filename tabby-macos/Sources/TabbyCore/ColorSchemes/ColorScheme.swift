import Foundation

/// A terminal colour scheme (`TerminalColorScheme` in `tabby-core/src/api/theme.ts`).
public struct ColorScheme: Hashable, Sendable, Identifiable {
    public var name: String
    public var foreground: String
    public var background: String
    public var cursor: String
    /// The 16 ANSI colours.
    public var colors: [String]
    public var selection: String?
    public var selectionForeground: String?
    public var cursorAccent: String?

    public var id: String { name }

    public init(name: String, foreground: String, background: String, cursor: String, colors: [String],
                selection: String? = nil, selectionForeground: String? = nil, cursorAccent: String? = nil) {
        self.name = name
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.colors = colors
        self.selection = selection
        self.selectionForeground = selectionForeground
        self.cursorAccent = cursorAccent
    }

    public init?(config v: ConfigValue?) {
        guard let v, let fg = v["foreground"]?.stringValue, let bg = v["background"]?.stringValue else { return nil }
        let colors = v["colors"]?.stringArrayValue ?? []
        guard colors.count >= 16 else { return nil }
        self.init(
            name: v["name"]?.stringValue ?? "Custom", // l10n-ignore: scheme names are config values
            foreground: fg,
            background: bg,
            cursor: v["cursor"]?.stringValue ?? fg,
            colors: Array(colors.prefix(16)),
            selection: v["selection"]?.stringValue,
            selectionForeground: v["selectionForeground"]?.stringValue,
            cursorAccent: v["cursorAccent"]?.stringValue
        )
    }

    public var configValue: ConfigValue {
        var o: [String: ConfigValue] = [
            "name": .string(name), "foreground": .string(foreground), "background": .string(background),
            "cursor": .string(cursor), "colors": .array(colors.map { .string($0) }),
        ]
        if let selection { o["selection"] = .string(selection) }
        if let selectionForeground { o["selectionForeground"] = .string(selectionForeground) }
        if let cursorAccent { o["cursorAccent"] = .string(cursorAccent) }
        return .object(o)
    }

    public var isDark: Bool {
        guard let bg = RGBColor(hex: background), let fg = RGBColor(hex: foreground) else { return true }
        return bg.luminance < fg.luminance
    }

    public func rgb(_ value: String) -> RGBColor { RGBColor(hex: value) ?? .black }
    public var foregroundRGB: RGBColor { rgb(foreground) }
    public var backgroundRGB: RGBColor { rgb(background) }
    public var cursorRGB: RGBColor { rgb(cursor) }
    public var paletteRGB: [RGBColor] { colors.map(rgb) }

    // MARK: Built-ins (tabby-terminal/src/colorSchemes.ts)

    public static let tabbyDefault = ColorScheme(
        name: "Tabby Default", foreground: "#cacaca", background: "#171717", cursor: "#bbbbbb", // l10n-ignore: scheme names are config values
        colors: ["#000000", "#ff615a", "#b1e969", "#ebd99c", "#5da9f6", "#e86aff", "#82fff7", "#dedacf",
                 "#313131", "#f58c80", "#ddf88f", "#eee5b2", "#a5c7ff", "#ddaaff", "#b7fff9", "#ffffff"]
    )

    public static let tabbyDefaultLight = ColorScheme(
        name: "Tabby Default Light", foreground: "#4d4d4c", background: "#ffffff", cursor: "#4d4d4c", // l10n-ignore: scheme names are config values
        colors: ["#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff",
                 "#000000", "#c82829", "#718c00", "#eab700", "#4271ae", "#8959a8", "#3e999f", "#ffffff"]
    )
}

/// Parser for the Xresources-format files in `tabby-community-color-schemes/schemes`.
/// Port of `tabby-community-color-schemes/src/colorSchemes.ts`.
public enum XresourcesParser {
    public static func parse(name: String, text: String) -> ColorScheme? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var variables: [String: String] = [:]
        for line in lines where line.hasPrefix("#define") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.count >= 3 { variables[parts[1]] = parts[2] }
        }
        var values: [String: String] = [:]
        for line in lines where line.hasPrefix("*.") {
            let body = line.dropFirst(2)
            guard let colon = body.firstIndex(of: ":") else { continue }
            let key = body[..<colon].trimmingCharacters(in: .whitespaces)
            let value = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            values[key] = variables[value] ?? value
        }
        var colors: [String] = []
        var i = 0
        while let c = values["color\(i)"], !c.isEmpty { // l10n-ignore: a config key
            colors.append(c)
            i += 1
        }
        guard let fg = values["foreground"], let bg = values["background"], colors.count >= 16 else { return nil }
        return ColorScheme(name: name.trimmingCharacters(in: .whitespaces), foreground: fg, background: bg,
                           cursor: values["cursorColor"] ?? fg, colors: Array(colors.prefix(16)))
    }
}

/// All known schemes: built-ins, the bundled community collection and the user's custom ones.
public final class ColorSchemeCatalog {
    public private(set) var bundled: [ColorScheme] = []

    public init(loadBundled: Bool = true) {
        if loadBundled { bundled = Self.loadBundledSchemes() }
    }

    public static func loadBundledSchemes() -> [ColorScheme] {
        guard let dir = Bundle.module.url(forResource: "schemes", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url -> ColorScheme? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return XresourcesParser.parse(name: url.lastPathComponent, text: text)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func all(custom: [ColorScheme]) -> [ColorScheme] {
        [ColorScheme.tabbyDefault, ColorScheme.tabbyDefaultLight] + custom + bundled
    }

    public static func customSchemes(from config: ConfigStore) -> [ColorScheme] {
        (config.value("terminal.customColorSchemes")?.arrayValue ?? []).compactMap { ColorScheme(config: $0) }
    }

    /// Renames a custom scheme, and the dark or light selection that uses it. Refuses an
    /// empty name or one another custom scheme has.
    @discardableResult
    public static func renameCustom(_ name: String, to newName: String, in config: ConfigStore) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        var list = config.value("terminal.customColorSchemes")?.arrayValue ?? []
        guard !trimmed.isEmpty, trimmed != name, !list.contains(where: { $0["name"]?.stringValue == trimmed }),
              let index = list.firstIndex(where: { $0["name"]?.stringValue == name }) else { return false }
        list[index]["name"] = .string(trimmed)
        config.set("terminal.customColorSchemes", .array(list))
        for key in ["colorScheme", "lightColorScheme"] where config.value(at: ["terminal", key, "name"])?.stringValue == name {
            config.set(at: ["terminal", key, "name"], .string(trimmed))
        }
        return true
    }

    /// Removes a custom scheme from the list; a selection or profile that embeds it keeps its
    /// colours (Tabby stores whole schemes there).
    public static func deleteCustom(_ name: String, in config: ConfigStore) {
        let list = (config.value("terminal.customColorSchemes")?.arrayValue ?? []).filter { $0["name"]?.stringValue != name }
        config.set("terminal.customColorSchemes", .array(list))
    }

    public enum Mode: String, CaseIterable, Sendable { case dark, light, auto }

    /// Port of `ThemesService._getActiveColorScheme`: picks `terminal.colorScheme` or
    /// `terminal.lightColorScheme` depending on `appearance.colorSchemeMode` and the system.
    public static func activeScheme(config: ConfigStore, systemIsDark: Bool, profileOverride: ConfigValue? = nil) -> ColorScheme {
        if let p = ColorScheme(config: profileOverride) { return p }
        let mode = Mode(rawValue: config.string("appearance.colorSchemeMode") ?? "dark") ?? .dark
        let useLight = mode == .light || (mode == .auto && !systemIsDark)
        if useLight {
            return ColorScheme(config: config.value("terminal.lightColorScheme")) ?? .tabbyDefaultLight
        }
        return ColorScheme(config: config.value("terminal.colorScheme")) ?? .tabbyDefault
    }
}
