#if canImport(AppKit)
import AppKit
import SwiftUI
import Observation
import TabbyCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case application = "Application"
    case appearance = "Appearance"
    case colorScheme = "Color scheme"
    case terminal = "Terminal"
    case window = "Window"
    case hotkeys = "Hotkeys"
    case profiles = "Profiles & connections"
    case ssh = "SSH"
    case configFile = "Config file"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .application: return "app.badge"
        case .appearance: return "paintbrush"
        case .colorScheme: return "swatchpalette"
        case .terminal: return "terminal"
        case .window: return "macwindow"
        case .hotkeys: return "keyboard"
        case .profiles: return "rectangle.stack"
        case .ssh: return "network"
        case .configFile: return "doc.text"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var section: SettingsSection? = .application
}

/// The Settings window (Tabby shows Settings as a tab; a separate window is the macOS norm).
@MainActor
final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?
    let navigation = SettingsNavigation()

    static func show(section: SettingsSection? = nil) {
        let controller = shared ?? SettingsWindowController()
        shared = controller
        if let section { controller.navigation.section = section }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.contentMinSize = CGSize(width: 720, height: 460)
        window.center()
        super.init(window: window)
        let hosting = NSHostingController(rootView: SettingsRootView(navigation: navigation))
        // By default the controller pushes SwiftUI's ideal size onto the window, which shrinks
        // it to a few rows. The user's frame (autosaved below) should win instead.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setFrameAutosaveName("TabbyMacSettingsWindow")
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct SettingsRootView: View {
    @Bindable var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $navigation.section) { section in
                Label(section.rawValue, systemImage: section.icon).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
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
                case .configFile: ConfigFileSettingsView()
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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

// MARK: - Sections

struct ApplicationSettingsView: View {
    @State private var importMessage: String?

    var body: some View {
        let services = AppServices.shared
        Form {
            Section("Configuration") {
                LabeledContent("Config file") {
                    HStack {
                        Text(services.paths.configFile.path).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([services.paths.configFile]) }
                    }
                }
                LabeledContent("Import from Tabby") {
                    VStack(alignment: .leading) {
                        Button("Import Tabby's config.yaml…") { importConfig() }
                        Text("Replaces these settings with \(ConfigPaths.electronTabbyConfig.path).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let importMessage { Text(importMessage).font(.callout) }
            }
            Section("Startup") {
                Toggle("Restore tabs on startup", isOn: ConfigBinding.bool("recoverTabs"))
                Toggle("Open a new tab when the app starts", isOn: ConfigBinding.bool("terminal.autoOpen"))
            }
            Section("Accessibility") {
                LabeledContent("Minimum contrast ratio") {
                    Stepper(value: ConfigBinding.double("terminal.minimumContrastRatio"), in: 1...21, step: 0.5) {
                        Text(String(format: "%.1f", AppServices.shared.config.double("terminal.minimumContrastRatio") ?? 4))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func importConfig() {
        let alert = NSAlert()
        alert.messageText = "Import Tabby's configuration?"
        alert.informativeText = "Your current TabbyMac settings, profiles and hotkeys will be replaced."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            importMessage = try AppServices.shared.importElectronTabbyConfig()
                ? "Imported. Some changes apply to new tabs only."
                : "No Tabby config found at \(ConfigPaths.electronTabbyConfig.path)."
        } catch {
            importMessage = error.localizedDescription
        }
    }
}

struct AppearanceSettingsView: View {
    var body: some View {
        let _ = AppServices.shared.configRevision
        Form {
            Section("Font") {
                Picker("Font", selection: ConfigBinding.string("terminal.font")) {
                    ForEach(Self.monospacedFamilies(including: AppServices.shared.config.string("terminal.font")), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                LabeledContent("Size") {
                    Stepper(value: ConfigBinding.double("terminal.fontSize"), in: 6...72, step: 1) {
                        Text("\(Int(AppServices.shared.config.double("terminal.fontSize") ?? 14)) pt")
                    }
                }
                Picker("Weight", selection: ConfigBinding.int("terminal.fontWeight")) {
                    ForEach([300, 400, 500, 600, 700], id: \.self) { Text("\($0)").tag($0) }
                }
                TextField("Fallback font", text: ConfigBinding.optionalString("terminal.fallbackFont"))
            }
            Section("Cursor") {
                Picker("Shape", selection: ConfigBinding.string("terminal.cursor")) {
                    Text("Block").tag("block")
                    Text("Beam").tag("beam")
                    Text("Underline").tag("underline")
                }
                Toggle("Blink", isOn: ConfigBinding.bool("terminal.cursorBlink"))
            }
            Section("Colors") {
                Toggle("Draw bold text in bright colors", isOn: ConfigBinding.bool("terminal.drawBoldTextInBrightColors"))
            }
        }
        .formStyle(.grouped)
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
        Form {
            Section("Window") {
                Picker("Title bar", selection: ConfigBinding.string("appearance.frame")) {
                    Text("Integrated with tabs").tag("thin")
                    Text("Native").tag("native")
                }
                Toggle("Vibrancy", isOn: ConfigBinding.bool("appearance.vibrancy"))
                LabeledContent("Opacity") {
                    Slider(value: ConfigBinding.double("appearance.opacity"), in: 0.4...1)
                }
                LabeledContent("Spaciness") {
                    Slider(value: ConfigBinding.double("appearance.spaciness"), in: 0.7...1.5)
                }
            }
            Section("Tabs") {
                Picker("Tab bar position", selection: ConfigBinding.string("appearance.tabsLocation")) {
                    Text("Top").tag("top")
                    Text("Bottom").tag("bottom")
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                Toggle("Stretch tabs to fill the bar", isOn: ConfigBinding.bool("appearance.flexTabs"))
                Toggle("Show tabs in full screen", isOn: ConfigBinding.bool("appearance.tabsInFullscreen"))
                Toggle("Cycle through tabs", isOn: ConfigBinding.bool("appearance.cycleTabs"))
                Toggle("Hide tab index", isOn: ConfigBinding.bool("terminal.hideTabIndex"))
                Toggle("Hide close button", isOn: ConfigBinding.bool("terminal.hideCloseButton"))
                Toggle("Show profile icon", isOn: ConfigBinding.bool("terminal.showTabProfileIcon"))
                Toggle("Closing the last tab closes the window", isOn: ConfigBinding.bool("appearance.lastTabClosesWindow"))
            }
            Section("Panes") {
                LabeledContent("Resize step") {
                    Slider(value: ConfigBinding.double("terminal.paneResizeStep"), in: 0.05...0.25)
                }
            }
            Section("Docking (Quake mode)") {
                Picker("Dock to", selection: ConfigBinding.string("appearance.dock")) {
                    Text("Off").tag("off")
                    Text("Top").tag("top")
                    Text("Bottom").tag("bottom")
                    Text("Left").tag("left")
                    Text("Right").tag("right")
                }
                LabeledContent("Size") { Slider(value: ConfigBinding.double("appearance.dockFill"), in: 0.2...1) }
                LabeledContent("Width") { Slider(value: ConfigBinding.double("appearance.dockSpace"), in: 0.2...1) }
                Toggle("Always on top", isOn: ConfigBinding.bool("appearance.dockAlwaysOnTop"))
                Text("Show or hide the window from anywhere with the \"Show/hide window (global)\" hotkey.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TerminalSettingsView: View {
    var body: some View {
        let _ = AppServices.shared.configRevision
        Form {
            Section("Behaviour") {
                LabeledContent("Scrollback lines") {
                    TextField("", value: ConfigBinding.int("terminal.scrollbackLines"), format: .number).frame(width: 100)
                }
                Picker("Bell", selection: ConfigBinding.string("terminal.bell")) {
                    Text("Off").tag("off")
                    Text("Visual").tag("visual")
                    Text("Audible").tag("audible")
                }
                Toggle("Option key acts as Meta", isOn: ConfigBinding.bool("terminal.altIsMeta"))
                Toggle("Scroll to bottom on input", isOn: ConfigBinding.bool("terminal.scrollOnInput"))
                Toggle("Show progress from output in the tab", isOn: ConfigBinding.bool("terminal.detectProgress"))
            }
            Section("Mouse") {
                Picker("Right click", selection: ConfigBinding.string("terminal.rightClick")) {
                    Text("Context menu").tag("menu")
                    Text("Paste").tag("paste")
                    Text("Copy, or paste when nothing is selected").tag("clipboard")
                    Text("Nothing").tag("off")
                }
                Toggle("Copy on select", isOn: ConfigBinding.bool("terminal.copyOnSelect"))
                Toggle("Paste on middle click", isOn: ConfigBinding.bool("terminal.pasteOnMiddleClick"))
            }
            Section("Clipboard") {
                Toggle("Bracketed paste", isOn: ConfigBinding.bool("terminal.bracketedPaste"))
                Toggle("Warn when pasting multiple lines", isOn: ConfigBinding.bool("terminal.warnOnMultilinePaste"))
                Toggle("Trim whitespace when pasting", isOn: ConfigBinding.bool("terminal.trimWhitespaceOnPaste"))
                Toggle("Replace newlines with spaces when pasting", isOn: ConfigBinding.bool("terminal.replaceNewlinesWithSpacesOnPaste"))
            }
            Section("Default profile") {
                Picker("New tabs open", selection: ConfigBinding.string("terminal.profile")) {
                    ForEach(AppServices.shared.profiles.allProfiles(includeHidden: true).filter { !$0.isTemplate }, id: \.id) { p in
                        Text(p.name).tag(p.id)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct SSHSettingsView: View {
    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        Form {
            Section("Security") {
                Toggle("Verify host keys", isOn: ConfigBinding.bool("ssh.verifyHostKeys"))
                LabeledContent("Known hosts") {
                    HStack {
                        Text(services.paths.knownHostsFile.path).lineLimit(1).truncationMode(.middle)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([services.paths.knownHostsFile]) }
                    }
                }
                Text("~/.ssh/known_hosts is also read. Passwords you choose to remember are stored in the login keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Connection") {
                Toggle("Warn when closing an open connection", isOn: ConfigBinding.bool("ssh.warnOnClose"))
                Picker("Quick connect uses", selection: ConfigBinding.string("defaultQuickConnectProvider")) {
                    Text("SSH").tag("ssh")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ConfigFileSettingsView: View {
    @State private var text = ""
    @State private var error: String?
    @State private var showDefaults = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("config.yaml").font(.headline)
                Spacer()
                Toggle("Show defaults", isOn: $showDefaults).toggleStyle(.switch)
                Button("Revert") { load() }
                Button("Save") { save() }.keyboardShortcut("s", modifiers: .command).disabled(showDefaults)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .disabled(showDefaults)
        }
        .padding()
        .onAppear(perform: load)
        .onChange(of: showDefaults) { load() }
    }

    private func load() {
        let config = AppServices.shared.config
        if showDefaults {
            text = (try? YAMLCoding.serialize(config.defaults.strippingMarkers())) ?? ""
        } else {
            text = (try? config.serializedUserConfig()) ?? ""
        }
        error = nil
    }

    private func save() {
        do {
            let value = try YAMLCoding.parse(text)
            AppServices.shared.config.replaceUser(value)
            AppServices.shared.flushSave()
            error = nil
        } catch {
            self.error = "Not saved: \(error)"
        }
    }
}
#endif
