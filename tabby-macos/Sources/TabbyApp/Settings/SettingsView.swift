#if canImport(AppKit)
import AppKit
import SwiftUI
import Observation
import TabbyCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case application = "Application" // l10n-ignore: id
    case appearance = "Appearance" // l10n-ignore: id
    case colorScheme = "Color scheme" // l10n-ignore: id
    case terminal = "Terminal" // l10n-ignore: id
    case window = "Window" // l10n-ignore: id
    case profiles = "Profiles & connections" // l10n-ignore: id
    case ssh = "SSH" // l10n-ignore: id
    case hotkeys = "Hotkeys" // l10n-ignore: id
    case vault = "Vault" // l10n-ignore: id
    case account = "Account & sync" // l10n-ignore: id
    case configFile = "Config file" // l10n-ignore: id

    var id: String { rawValue }

    /// The sidebar and page title in the current language.
    var title: String {
        switch self {
        case .application: return L("Application")
        case .appearance: return L("Appearance")
        case .colorScheme: return L("Color scheme")
        case .terminal: return L("Terminal")
        case .window: return L("Window")
        case .profiles: return L("Profiles & connections")
        case .ssh: return L("SSH")
        case .hotkeys: return L("Hotkeys")
        case .vault: return L("Vault")
        case .account: return L("Account & sync")
        case .configFile: return L("Config file")
        }
    }

    /// SF Symbols from the design's icon table.
    var icon: String {
        switch self {
        case .application: return "square.grid.2x2"
        case .appearance: return "paintbrush"
        case .colorScheme: return "paintpalette"
        case .terminal: return "terminal"
        case .window: return "macwindow"
        case .profiles: return "rectangle.stack"
        case .ssh: return "server.rack"
        case .hotkeys: return "keyboard"
        case .vault: return "key"
        case .account: return "person.crop.circle"
        case .configFile: return "curlybraces"
        }
    }

    /// The sidebar groups of the design.
    static let groups: [[SettingsSection]] = [
        [.application, .appearance, .colorScheme, .terminal, .window],
        [.profiles, .ssh, .hotkeys, .vault],
        [.account, .configFile],
    ]

    /// Row labels on the page, so "Search settings" finds a page by what is on it.
    var keywords: [String] {
        switch self {
        case .application: return ["config file", "import", "startup", "restore tabs", "contrast", "accessibility"] // l10n-ignore: English search keywords (titles are matched translated)
        case .appearance: return ["theme", "dark", "light", "system", "font", "size", "weight", "cursor", "blink", "bold", "tabs", "flex", "index", "icon", "close button"] // l10n-ignore: English search keywords (titles are matched translated)
        case .colorScheme: return ["scheme", "colors", "colours", "palette", "dark", "light"] // l10n-ignore: English search keywords (titles are matched translated)
        case .terminal: return ["scrollback", "bell", "flash", "dock icon", "meta", "option", "right click", "copy on select", "paste", "bracketed", "progress", "default profile"] // l10n-ignore: English search keywords (titles are matched translated)
        case .window: return ["frame", "title bar", "tab bar", "location", "spaciness", "vibrancy", "opacity", "dock", "quake", "always on top", "global hotkey", "full screen", "cycle", "pane"] // l10n-ignore: English search keywords (titles are matched translated)
        case .profiles: return ["profile", "connection", "group", "ssh", "local", "default", "hidden"] // l10n-ignore: English search keywords (titles are matched translated)
        case .ssh: return ["host key", "known hosts", "warn", "quick connect", "keychain"] // l10n-ignore: English search keywords (titles are matched translated)
        case .hotkeys: return ["shortcut", "keyboard", "chord", "binding"] // l10n-ignore: English search keywords (titles are matched translated)
        case .vault: return ["password", "passphrase", "keychain", "secret", "key"] // l10n-ignore: English search keywords (titles are matched translated)
        case .account: return ["sync", "sign in", "sign out", "devices", "recovery key", "cloud", "email"] // l10n-ignore: English search keywords (titles are matched translated)
        case .configFile: return ["yaml", "config.yaml", "raw"] // l10n-ignore: English search keywords (titles are matched translated)
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return title.lowercased().contains(q) || rawValue.lowercased().contains(q) || keywords.contains { $0.contains(q) }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var section: SettingsSection? = .application
    var search = ""
}

/// Settings tab: a 220 pt sidebar with search and grouped sections, and the page.
struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(navigation: navigation)
                .frame(width: 220)
                .background(chrome.surfaceChrome.color)
            Rectangle().fill(chrome.separator.color).frame(width: 1)
            Group {
                switch navigation.section ?? .application {
                case .application: ApplicationSettingsView()
                case .appearance: AppearanceSettingsView()
                case .colorScheme: ColorSchemeSettingsView()
                case .terminal: TerminalSettingsView()
                case .window: WindowSettingsView()
                case .hotkeys: HotkeysSettingsView()
                case .profiles: ProfilesSettingsView()
                case .ssh: SSHSettingsView()
                case .vault: VaultSettingsView()
                case .account: AccountSettingsView()
                case .configFile: ConfigFileSettingsView()
                }
            }
            // Take the width the window gives and never more: a page wider than that would
            // grow the tab and push the sidebar off the left edge.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .background(chrome.surface.color)
        }
        .foregroundStyle(chrome.text.color)
    }
}

struct SettingsSidebar: View {
    @Bindable var navigation: SettingsNavigation
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(chrome.textMuted.color)
                TextField(L("Search settings"), text: $navigation.search)
                    .textFieldStyle(.plain)
                    .font(ChromeFont.body)
                    .onSubmit {
                        if let first = SettingsSection.allCases.first(where: { $0.matches(navigation.search) }) {
                            navigation.section = first
                        }
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(chrome.fill.color))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(SettingsSection.groups.enumerated()), id: \.offset) { _, group in
                        let shown = group.filter { $0.matches(navigation.search) }
                        if !shown.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(shown) { section in row(section) }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .padding(.top, 4)
    }

    private func row(_ section: SettingsSection) -> some View {
        let selected = navigation.section == section
        return Button { navigation.section = section } label: {
            HStack(spacing: 8) {
                Image(systemName: section.icon).font(.system(size: 13))
                    .foregroundStyle((selected ? chrome.onAccent : chrome.textMuted).color)
                    .frame(width: 18)
                Text(section.title).font(ChromeFont.body)
                    .foregroundStyle((selected ? chrome.onAccent : chrome.text).color)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? chrome.accent.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Config bindings

/// SwiftUI bindings straight onto `ConfigStore` paths.
@MainActor
enum ConfigBinding {
    static var config: ConfigStore { AppServices.shared.config }

    static func bool(_ path: String) -> Binding<Bool> {
        Binding(get: { _ = AppServices.shared.configRevision; return config.value(path)?.boolValue ?? false },
                set: { config.set(path, .bool($0)) })
    }

    /// For settings Tabby stores as `hide…`, shown as "Show …".
    static func inverted(_ path: String) -> Binding<Bool> {
        Binding(get: { _ = AppServices.shared.configRevision; return !(config.value(path)?.boolValue ?? false) },
                set: { config.set(path, .bool(!$0)) })
    }

    static func string(_ path: String) -> Binding<String> {
        Binding(get: { _ = AppServices.shared.configRevision; return config.string(path) ?? "" },
                set: { config.set(path, .string($0)) })
    }

    static func optionalString(_ path: String) -> Binding<String> {
        Binding(get: { _ = AppServices.shared.configRevision; return config.string(path) ?? "" },
                set: { config.set(path, $0.isEmpty ? .null : .string($0)) })
    }

    static func double(_ path: String) -> Binding<Double> {
        Binding(get: { _ = AppServices.shared.configRevision; return config.double(path) ?? 0 },
                set: { config.set(path, .double($0)) })
    }

    static func int(_ path: String) -> Binding<Int> {
        Binding(get: { _ = AppServices.shared.configRevision; return config.int(path) ?? 0 },
                set: { config.set(path, .int($0)) })
    }
}

// MARK: - Controls

/// A small menu-style popup with no label of its own (the row has it).
struct RowPicker<Value: Hashable, Content: View>: View {
    let selection: Binding<Value>
    @ViewBuilder var content: Content

    var body: some View {
        Picker("", selection: selection) { content }.labelsHidden().fixedSize()
    }
}

/// Segmented control sized to its content.
struct RowSegments<Value: Hashable, Content: View>: View {
    let selection: Binding<Value>
    @ViewBuilder var content: Content

    var body: some View {
        Picker("", selection: selection) { content }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}

/// Slider with the range ends and the current value, as in the design.
struct RowSlider: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 10) {
            Text(format(range.lowerBound)).font(.system(size: 11)).foregroundStyle(chrome.textFaint.color)
            Group {
                if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            }
            .controlSize(.small)
            .tint(chrome.accent.color)
            .frame(width: 180)
            Text(format(range.upperBound)).font(.system(size: 11)).foregroundStyle(chrome.textFaint.color)
            Text(format(value.wrappedValue)).font(.custom("Menlo", size: 11)).frame(width: 40, alignment: .trailing)
        }
    }
}

/// A value well with a stepper.
struct RowStepper: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 6) {
            Text(format(value.wrappedValue)).monospacedDigit()
                .padding(.horizontal, 7)
                .frame(minWidth: 44, minHeight: 22, alignment: .trailing)
                .background(RoundedRectangle(cornerRadius: 5).fill(chrome.surface.color))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(chrome.border.color, lineWidth: 0.5))
            Stepper("", value: value, in: range, step: step).labelsHidden()
        }
    }
}

/// A text field in the design's well style (Menlo 12, 220 pt).
struct RowField: View {
    let placeholder: String
    let text: Binding<String>
    var width: CGFloat = 220

    var body: some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.custom("Menlo", size: 12))
            .frame(width: width)
    }
}

/// A file path with a "Show in Finder" button.
struct RowPath: View {
    let url: URL
    @Environment(\.chrome) private var chrome

    var body: some View {
        HStack(spacing: 8) {
            Text((url.path as NSString).abbreviatingWithTildeInPath)
                .font(.custom("Menlo", size: 11)).foregroundStyle(chrome.textMuted.color)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(ChromeButtonStyle())
        }
    }
}

// MARK: - Pages

struct ApplicationSettingsView: View {
    @State private var importMessage: String?
    /// Bumped after "Use TabbyMac" so the handler line is read again.
    @State private var linkRevision = 0

    private var linkSubtitle: String {
        _ = linkRevision
        if LinkHandlers.isDefault { return L("TabbyMac opens them") }
        return LinkHandlers.handlerName(for: "ssh").map { L("Now opened by {app}", ["app": $0]) } ?? L("No app opens them yet")
    }

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        SettingsPage(L("Application")) {
            SettingsGroup {
                SettingsRow(L("Language"), subtitle: L("Automatic follows the system language")) { LanguagePicker() }
            }
            SettingsGroup(L("Configuration"), footer: importMessage) {
                SettingsRow(L("Config file")) { RowPath(url: services.paths.configFile) }
                SettingsRow(L("Import from Tabby"), subtitle: L("Replaces these settings with {path}", ["path": (ConfigPaths.electronTabbyConfig.path as NSString).abbreviatingWithTildeInPath])) {
                    Button(L("Import…")) { importConfig() }.buttonStyle(ChromeButtonStyle())
                }
            }
            if LinkHandlers.canChange {
                SettingsGroup(L("Links")) {
                    SettingsRow(L("Open ssh:// and telnet:// links"), subtitle: linkSubtitle) {
                        Button(L("Use TabbyMac")) { LinkHandlers.makeDefault { linkRevision += 1 } }
                            .buttonStyle(ChromeButtonStyle()).disabled(LinkHandlers.isDefault)
                    }
                }
            }
            SettingsGroup(L("Command-line tool"), footer: L("tabby open, run, profile, paste, recent and quickConnect, as in Tabby.")) {
                SettingsRow("tabby", subtitle: LinkHandlers.cliPath) { // l10n-ignore: the command's name
                    Button(L("Copy install command")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(LinkHandlers.installCommand, forType: .string)
                    }
                    .buttonStyle(ChromeButtonStyle())
                }
            }
            SettingsGroup(L("Startup")) {
                SettingsRow(L("Restore tabs on startup"), isOn: ConfigBinding.bool("recoverTabs"))
                SettingsRow(L("Open a new tab when the app starts"), isOn: ConfigBinding.bool("terminal.autoOpen"))
                SettingsRow(L("Show the Welcome tab"), isOn: ConfigBinding.bool("enableWelcomeTab"))
            }
            SettingsGroup(L("Accessibility")) {
                SettingsRow(L("Minimum contrast ratio"), subtitle: L("Text that is harder to read than this is brightened or darkened")) {
                    RowStepper(value: ConfigBinding.double("terminal.minimumContrastRatio"), range: 1...21, step: 0.5) { String(format: "%.1f", $0) }
                }
            }
        }
    }

    private func importConfig() {
        let alert = NSAlert()
        alert.messageText = L("Import Tabby's configuration?")
        alert.informativeText = L("Your current TabbyMac settings, profiles and hotkeys will be replaced.")
        alert.addButton(withTitle: L("Import"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            importMessage = try AppServices.shared.importElectronTabbyConfig()
                ? L("Imported. Some changes apply to new tabs only.")
                : L("No Tabby config found at {path}.", ["path": ConfigPaths.electronTabbyConfig.path])
        } catch {
            importMessage = error.localizedDescription
        }
    }
}

struct AppearanceSettingsView: View {
    var body: some View {
        let config = AppServices.shared.config
        let _ = AppServices.shared.configRevision
        SettingsPage(L("Appearance")) {
            SettingsGroup(L("Theme")) {
                SettingsRow(L("Appearance"), subtitle: L("The window takes its colours from the active colour scheme")) {
                    RowSegments(selection: ConfigBinding.string("appearance.colorSchemeMode")) {
                        Text(L("System")).tag("auto")
                        Text(L("Dark")).tag("dark")
                        Text(L("Light")).tag("light")
                    }
                }
            }
            SettingsGroup(L("Terminal font")) {
                SettingsRow(L("Font")) {
                    RowPicker(selection: ConfigBinding.string("terminal.font")) {
                        ForEach(Self.monospacedFamilies(including: config.string("terminal.font")), id: \.self) { Text($0).tag($0) }
                    }
                }
                SettingsRow(L("Size")) {
                    RowStepper(value: ConfigBinding.double("terminal.fontSize"), range: 6...72, step: 1) { "\(Int($0)) pt" } // l10n-ignore: a unit
                }
                SettingsRow(L("Weight")) {
                    RowPicker(selection: ConfigBinding.int("terminal.fontWeight")) {
                        ForEach([300, 400, 500, 600, 700], id: \.self) { Text("\($0)").tag($0) }
                    }
                }
                SettingsRow(L("Fallback font")) { RowField(placeholder: L("None"), text: ConfigBinding.optionalString("terminal.fallbackFont")) }
                SettingsRow(L("Draw bold text in bright colours"), isOn: ConfigBinding.bool("terminal.drawBoldTextInBrightColors"))
            }
            SettingsGroup(L("Cursor")) {
                SettingsRow(L("Shape")) {
                    RowSegments(selection: ConfigBinding.string("terminal.cursor")) {
                        Text(L("Block")).tag("block")
                        Text(L("Beam")).tag("beam")
                        Text(L("Underline")).tag("underline")
                    }
                }
                SettingsRow(L("Blink"), isOn: ConfigBinding.bool("terminal.cursorBlink"))
            }
            SettingsGroup(L("Tabs")) {
                SettingsRow(L("Flex tabs"), subtitle: L("Tabs stretch to fill the tab bar instead of using a fixed width"),
                            isOn: ConfigBinding.bool("appearance.flexTabs"))
                SettingsRow(L("Show tab index"), isOn: ConfigBinding.inverted("terminal.hideTabIndex"))
                SettingsRow(L("Show profile icon"), isOn: ConfigBinding.bool("terminal.showTabProfileIcon"))
                SettingsRow(L("Show close button"), subtitle: L("On the active tab and on hover"),
                            isOn: ConfigBinding.inverted("terminal.hideCloseButton"))
            }
        }
    }

    static func monospacedFamilies(including current: String?) -> [String] {
        let manager = NSFontManager.shared
        var families = manager.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch || family.lowercased().contains("mono")
        }
        if let current, !families.contains(current) { families.insert(current, at: 0) }
        return families
    }
}

struct WindowSettingsView: View {
    var body: some View {
        let _ = AppServices.shared.configRevision
        let percent: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        SettingsPage(L("Window")) {
            SettingsGroup(L("Frame")) {
                SettingsRow(L("Window frame")) {
                    RowPicker(selection: ConfigBinding.string("appearance.frame")) {
                        Text(L("Hidden title bar")).tag("thin")
                        Text(L("Native")).tag("native")
                    }
                }
                SettingsRow(L("Tab bar location")) {
                    RowSegments(selection: ConfigBinding.string("appearance.tabsLocation")) {
                        Text(L("Top")).tag("top")
                        Text(L("Bottom")).tag("bottom")
                        Text(L("Left")).tag("left")
                        Text(L("Right")).tag("right")
                    }
                }
                SettingsRow(L("Spaciness"), subtitle: L("Scales paddings and the tab bar height (38 pt at 1.0)")) {
                    RowSlider(value: ConfigBinding.double("appearance.spaciness"), range: 0.8...1.5, step: 0.05) { String(format: "%.2g", $0) }
                }
            }
            SettingsGroup(L("Transparency")) {
                SettingsRow(L("Vibrancy"), subtitle: L("Translucent, blurred window background"), isOn: ConfigBinding.bool("appearance.vibrancy"))
                SettingsRow(L("Window opacity")) {
                    RowSlider(value: ConfigBinding.double("appearance.opacity"), range: 0.5...1, format: percent)
                }
            }
            SettingsGroup(L("Tabs")) {
                SettingsRow(L("Show tabs in full screen"), isOn: ConfigBinding.bool("appearance.tabsInFullscreen"))
                SettingsRow(L("Cycle through tabs"), subtitle: L("Next tab on the last tab goes back to the first"),
                            isOn: ConfigBinding.bool("appearance.cycleTabs"))
                SettingsRow(L("Closing the last tab closes the window"), isOn: ConfigBinding.bool("appearance.lastTabClosesWindow"))
            }
            SettingsGroup(L("Panes")) {
                SettingsRow(L("Focus follows mouse"), subtitle: L("Moving the mouse over an inactive pane will cause it to activate"),
                            isOn: ConfigBinding.bool("terminal.focusFollowsMouse"))
                SettingsRow(L("Pane resize step")) {
                    RowSlider(value: ConfigBinding.double("terminal.paneResizeStep"), range: 0.05...0.25, format: percent)
                }
            }
            SettingsGroup(L("Dock"), footer: L("Docked windows slide in and out with the global hotkey, like a Quake console.")) {
                SettingsRow(L("Dock to screen edge")) {
                    RowPicker(selection: ConfigBinding.string("appearance.dock")) {
                        Text(L("Off")).tag("off")
                        Text(L("Top")).tag("top")
                        Text(L("Bottom")).tag("bottom")
                        Text(L("Left")).tag("left")
                        Text(L("Right")).tag("right")
                    }
                }
                SettingsRow(L("Docked size")) {
                    RowSlider(value: ConfigBinding.double("appearance.dockFill"), range: 0.2...1, format: percent)
                }
                SettingsRow(L("Docked width")) {
                    RowSlider(value: ConfigBinding.double("appearance.dockSpace"), range: 0.2...1, format: percent)
                }
                SettingsRow(L("Always on top when docked"), isOn: ConfigBinding.bool("appearance.dockAlwaysOnTop"))
                SettingsRow(L("Show / hide (global)")) {
                    HStack(spacing: 4) {
                        let keys = HotkeyBinding.bindings(from: AppServices.shared.config.value("hotkeys.toggle-window"))
                        if keys.isEmpty { Text(L("Not set")).foregroundStyle(.secondary) }
                        ForEach(Array(keys.enumerated()), id: \.offset) { _, b in Keycap(b.symbolicDescription) }
                    }
                }
            }
        }
    }
}

struct TerminalSettingsView: View {
    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        SettingsPage(L("Terminal")) {
            SettingsGroup(L("Input")) {
                SettingsRow(L("Copy on select"), isOn: ConfigBinding.bool("terminal.copyOnSelect"))
                SettingsRow(L("Right click")) {
                    RowPicker(selection: ConfigBinding.string("terminal.rightClick")) {
                        Text(L("Context menu")).tag("menu")
                        Text(L("Paste")).tag("paste")
                        Text(L("Copy, or paste when nothing is selected")).tag("clipboard")
                        Text(L("Nothing")).tag("off")
                    }
                }
                SettingsRow(L("Paste on middle click"), isOn: ConfigBinding.bool("terminal.pasteOnMiddleClick"))
                SettingsRow(L("Option key acts as Meta"), isOn: ConfigBinding.bool("terminal.altIsMeta"))
                SettingsRow(L("Scroll to bottom on input"), isOn: ConfigBinding.bool("terminal.scrollOnInput"))
                SettingsRow(L("Word separators"), subtitle: L("Double-click selection will stop at these characters")) {
                    RowField(placeholder: TerminalTextDefaults.wordSeparator, text: ConfigBinding.optionalString("terminal.wordSeparator"), width: 140)
                }
            }
            SettingsGroup(L("Clipboard")) {
                SettingsRow(L("Warn before pasting multiple lines"), isOn: ConfigBinding.bool("terminal.warnOnMultilinePaste"))
                SettingsRow(L("Bracketed paste"), isOn: ConfigBinding.bool("terminal.bracketedPaste"))
                SettingsRow(L("Trim whitespace when pasting"), isOn: ConfigBinding.bool("terminal.trimWhitespaceOnPaste"))
                SettingsRow(L("Replace newlines with spaces"), isOn: ConfigBinding.bool("terminal.replaceNewlinesWithSpacesOnPaste"))
                SettingsRow(L("Copy with formatting"), isOn: ConfigBinding.bool("terminal.copyAsHTML"))
            }
            SettingsGroup(L("Output")) {
                SettingsRow(L("Bell")) {
                    RowSegments(selection: ConfigBinding.string("terminal.bell")) {
                        Text(L("Off")).tag("off")
                        Text(L("Visual")).tag("visual")
                        Text(L("Audible")).tag("audible")
                    }
                }
                SettingsRow(L("Flash the Dock icon"), subtitle: L("When the bell rings while TabbyMac is in the background"),
                           isOn: ConfigBinding.bool("terminal.bellFlashFrame"))
                SettingsRow(L("Scrollback")) {
                    RowStepper(value: Binding(get: { Double(ConfigBinding.int("terminal.scrollbackLines").wrappedValue) },
                                              set: { ConfigBinding.int("terminal.scrollbackLines").wrappedValue = Int($0) }),
                               range: 1000...1_000_000, step: 1000) { L("{count} lines", ["count": Int($0).formatted()]) }
                }
                SettingsRow(L("Detect progress in output"), subtitle: L("Shows a percentage in the tab when a command prints one"),
                            isOn: ConfigBinding.bool("terminal.detectProgress"))
            }
            SettingsGroup(L("New tabs")) {
                SettingsRow(L("Default profile")) {
                    RowPicker(selection: ConfigBinding.string("terminal.profile")) {
                        ForEach(services.profiles.allProfiles(includeHidden: true).filter { !$0.isTemplate }, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                }
            }
        }
    }
}

struct SSHSettingsView: View {
    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        SettingsPage(L("SSH")) {
            SettingsGroup(L("Connections"), footer: L("~/.ssh/known_hosts is read as well. Passwords you choose to remember are kept in the login keychain.")) {
                SettingsRow(L("Verify host keys"), subtitle: L("Ask before connecting to a host whose key is unknown or changed"),
                            isOn: ConfigBinding.bool("ssh.verifyHostKeys"))
                SettingsRow(L("Known hosts file")) { RowPath(url: services.paths.knownHostsFile) }
                SettingsRow(L("Warn when closing an open connection"), isOn: ConfigBinding.bool("ssh.warnOnClose"))
                SettingsRow(L("Quick connect uses")) {
                    RowPicker(selection: ConfigBinding.string("defaultQuickConnectProvider")) {
                        ForEach(ProfileTypes.quickConnectProviders, id: \.id) { Text(ProfileTypes.badge($0.id)).tag($0.id) }
                    }
                }
            }
            SettingsGroup(L("Agent and X11"), footer: L("Used by SSH connections on the built-in client (ssh.backend: library, the default).")) {
                SettingsRow(L("SSH agent"), subtitle: L("A socket path; empty uses the system agent (SSH_AUTH_SOCK)")) {
                    RowField(placeholder: L("System (SSH_AUTH_SOCK)"), text: ConfigBinding.optionalString("ssh.agentPath"), width: 260)
                }
                SettingsRow(L("X11 display"), subtitle: L("Where forwarded X11 connections go; empty uses $DISPLAY")) {
                    RowField(placeholder: ProcessInfo.processInfo.environment["DISPLAY"] ?? "localhost:0",
                             text: ConfigBinding.optionalString("ssh.x11Display"), width: 260)
                }
            }
        }
    }
}
#endif
