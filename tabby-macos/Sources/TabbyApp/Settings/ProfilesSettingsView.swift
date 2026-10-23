#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbySSHLib
import TabbyCore
import TabbyTerminal

/// Profiles & connections (Tabby's `ProfilesSettingsTabComponent` + `EditProfileModal`), in the
/// phase 2 design: an outline of groups and profiles with a bottom bar; ↩ or a double click
/// opens the editor.
struct ProfilesSettingsView: View {
    @State private var editing: EditableProfile?
    @State private var filter = ""
    @State private var showHidden = false
    @State private var selection: String?
    @State private var collapsed: Set<String> = []
    @Environment(\.chrome) private var chrome

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let registry = services.profiles
        let defaultId = services.config.string("terminal.profile") ?? "local:default"
        let all = FuzzyMatcher.filter(registry.allProfiles(includeHidden: showHidden), query: filter) { "\($0.name) \(registry.groupPath($0.group))" }
        let sections = Self.sections(all, registry: registry)
        let selected = all.first { $0.id == selection }
        SettingsPage(L("Profiles & connections")) {
            SettingsGroup {
                SettingsRow(L("Default profile for new tabs")) {
                    RowPicker(selection: ConfigBinding.string("terminal.profile")) {
                        ForEach(registry.allProfiles(includeHidden: true).filter { !$0.isTemplate }, id: \.id) { p in Text(p.name).tag(p.id) }
                    }
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
                    TextField(L("Filter profiles"), text: $filter).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(chrome.fill.color))
                Toggle(L("Show hidden"), isOn: $showHidden).toggleStyle(.checkbox)
                Menu {
                    ForEach(ProfileTypes.creatable, id: \.self) { type in
                        Button {
                            editing = EditableProfile(ProfileTypes.newProfile(type), isNew: true)
                        } label: {
                            // Menus drop a label's icon unless asked (design C7c shows them).
                            Label(ProfileTypes.title(type), systemImage: ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: type)))
                                .labelStyle(.titleAndIcon)
                        }
                    }
                } label: {
                    Label(L("New"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(chrome.accent.color))
                .foregroundStyle(chrome.onAccent.color)
            }
            VStack(spacing: 0) {
                VStack(spacing: 1) {
                    ForEach(sections) { section in
                        GroupRow(title: section.title, count: section.profiles.count, color: section.color,
                                 isOpen: !collapsed.contains(section.title)) {
                            if collapsed.contains(section.title) { collapsed.remove(section.title) } else { collapsed.insert(section.title) }
                        }
                        if !collapsed.contains(section.title) {
                            ForEach(section.profiles, id: \.id) { p in
                                ProfileListRow(profile: p, description: registry.provider(for: p.type)?.description(for: p) ?? p.type,
                                               isDefault: p.id == defaultId, isSelected: p.id == selection)
                                    .onTapGesture(count: 2) { edit(p) }
                                    .simultaneousGesture(TapGesture().onEnded { selection = p.id })
                                    .contextMenu { menu(for: p, registry: registry) }
                            }
                        }
                    }
                    if sections.isEmpty {
                        Text(filter.isEmpty ? L("No profiles") : L("No profiles match “{filter}”", ["filter": filter]))
                            .foregroundStyle(chrome.textMuted.color).padding(20)
                    }
                }
                .padding(6)
                Rectangle().fill(chrome.separator.color).frame(height: 1)
                HStack(spacing: 4) {
                    IconButton(symbol: "plus", help: L("New local profile"), size: 24) { editing = EditableProfile(ProfileTypes.newProfile("local"), isNew: true) }
                    IconButton(symbol: "minus", help: L("Delete profile"), size: 24) { if let selected { delete(selected, registry: registry) } }
                        .disabled(selected.map { $0.isBuiltin } ?? true)
                    Rectangle().fill(chrome.separator.color).frame(width: 1, height: 16).padding(.horizontal, 4)
                    Button { if let selected { duplicate(selected) } } label: { Label(L("Duplicate"), systemImage: "doc.on.doc") }
                        .disabled(selected == nil)
                    Button { if let selected { toggleHidden(selected, registry: registry) } } label: {
                        Label(selected?.extra["hidden"]?.boolValue == true ? L("Unhide") : L("Hide"), systemImage: "eye.slash")
                    }
                    .disabled(selected.map { $0.isBuiltin } ?? true)
                    Button { newGroup(registry: registry) } label: { Label(L("New group"), systemImage: "folder.badge.plus") }
                    Spacer()
                    Button(selected?.isBuiltin == true ? "Duplicate…" : "Edit…") { if let selected { edit(selected) } }
                        .buttonStyle(ChromeButtonStyle(kind: .primary))
                        .keyboardShortcut(.defaultAction)
                        .disabled(selected == nil)
                }
                .buttonStyle(.plain)
                .font(ChromeFont.caption)
                .foregroundStyle(chrome.textMuted.color)
                .padding(.horizontal, 8)
                .frame(height: 36)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
        }
        .sheet(item: $editing) { item in
            ProfileEditorSheet(item: item) { result in
                editing = nil
                if let result { selection = registry.save(result).id }
            }
            .chromeEnvironment()
        }
    }

    @ViewBuilder
    private func menu(for p: Profile, registry: ProfileRegistry) -> some View {
        Button(L("Open in a new tab")) { _ = WindowManager.shared.activeController?.model.openTab(profile: p) }
        Button(L("Use for new tabs")) { AppServices.shared.config.set("terminal.profile", .string(p.id)) }
        Divider()
        if !p.isBuiltin { Button(L("Edit…")) { edit(p) } }
        Button(L("Duplicate")) { duplicate(p) }
        if !p.isBuiltin {
            Button(p.extra["hidden"]?.boolValue == true ? L("Unhide") : L("Hide")) { toggleHidden(p, registry: registry) }
            Divider()
            Button(L("Delete…"), role: .destructive) { delete(p, registry: registry) }
        }
    }

    private func edit(_ p: Profile) {
        if p.isBuiltin { duplicate(p) } else { editing = EditableProfile(p, isNew: false) }
    }

    private func duplicate(_ p: Profile) {
        var copy = p
        copy.id = ""
        copy.isBuiltin = false
        copy.name = p.name + " (copy)"
        copy.extra["hidden"] = nil
        editing = EditableProfile(copy, isNew: true)
    }

    private func toggleHidden(_ p: Profile, registry: ProfileRegistry) {
        var copy = p
        copy.extra["hidden"] = p.extra["hidden"]?.boolValue == true ? nil : true
        _ = registry.save(copy)
    }

    private func delete(_ p: Profile, registry: ProfileRegistry) {
        guard !p.isBuiltin else { return }
        Prompts.confirm(in: NSApp.keyWindow, title: L("Delete “{name}”?", ["name": p.name]),
                        message: L("The profile is removed here and, when profiles sync, on your other Macs. A password saved for it stays in the Keychain (Settings › Vault)."),
                        confirm: L("Delete"), destructive: true) { ok in
            guard ok else { return }
            registry.delete(profileId: p.id)
            if selection == p.id { selection = nil }
        }
    }

    private func newGroup(registry: ProfileRegistry) {
        Prompts.text(in: NSApp.keyWindow, title: L("New group"), value: "", confirm: L("Create")) { name, _ in
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !registry.groups.contains(where: { $0.name == name }) else { return }
            registry.save(ProfileGroup(name: name))
        }
    }

    struct ProfileSection: Identifiable {
        let title: String
        let color: String?
        let profiles: [Profile]
        var id: String { title }
    }

    static func sections(_ profiles: [Profile], registry: ProfileRegistry) -> [ProfileSection] {
        var order: [String] = []
        var map: [String: [Profile]] = [:]
        var colors: [String: String] = [:]
        for p in profiles where !p.isTemplate {
            let title = p.isBuiltin ? (p.group ?? L("Built-in")) : (registry.groupPath(p.group).isEmpty ? L("Ungrouped") : registry.groupPath(p.group))
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(p)
            if let g = registry.groups.first(where: { $0.id == p.group }), let c = g.color { colors[title] = c }
        }
        // User groups first, built-in and imported groups last, as in the design.
        let builtinTitles = Set(profiles.filter(\.isBuiltin).map { $0.group ?? "Built-in" })
        let sorted = order.filter { !builtinTitles.contains($0) } + order.filter { builtinTitles.contains($0) }
        return sorted.map { ProfileSection(title: $0, color: colors[$0], profiles: map[$0] ?? []) }
    }
}

private struct GroupRow: View {
    let title: String
    let count: Int
    let color: String?
    let isOpen: Bool
    let toggle: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(chrome.textFaint.color).frame(width: 12)
                Image(systemName: "folder").foregroundStyle((color.flatMap(RGBColor.init(hex:)) ?? chrome.textMuted).color)
                Text(title).font(ChromeFont.bodyEmphasised)
                Text("\(count)").font(ChromeFont.caption).foregroundStyle(chrome.textFaint.color)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProfileListRow: View {
    let profile: Profile
    let description: String
    let isDefault: Bool
    let isSelected: Bool
    @Environment(\.chrome) private var chrome

    var body: some View {
        let hidden = profile.extra["hidden"]?.boolValue == true
        let tint = profile.color.flatMap(RGBColor.init(hex:))
        let fg = isSelected ? chrome.onAccent : chrome.text
        let muted = isSelected ? chrome.onAccent.withAlpha(0.75) : chrome.textMuted
        HStack(spacing: 8) {
            Image(systemName: ProfileIcons.symbol(for: profile.icon ?? ProfileIcons.defaultIcon(forType: profile.type)))
                .foregroundStyle((isSelected ? chrome.onAccent : (tint ?? chrome.textMuted)).color)
                .frame(width: 18)
            Text(profile.name).foregroundStyle(fg.color).lineLimit(1)
            Text(description).font(ChromeFont.caption).foregroundStyle(muted.color).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let tint { StatusDot(color: tint, size: 7) }
            if hidden { Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(muted.color) }
            if isDefault {
                Text(L("Default")).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 16)
                    .foregroundStyle((isSelected ? chrome.onAccent : chrome.accent).color)
                    .background(Capsule().fill((isSelected ? chrome.onAccent.withAlpha(0.2) : chrome.accentFill).color))
            }
            Text(ProfileTypes.badge(profile.type)).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 16)
                .foregroundStyle(muted.color)
                .background(RoundedRectangle(cornerRadius: 4).fill((isSelected ? chrome.onAccent.withAlpha(0.2) : chrome.fill).color))
        }
        .padding(.leading, 34)
        .padding(.trailing, 10)
        .frame(height: 30)
        .opacity(hidden ? 0.6 : 1)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? chrome.accent.color : .clear))
        .contentShape(Rectangle())
    }

}

struct EditableProfile: Identifiable {
    let id = UUID()
    var profile: Profile
    var isNew: Bool

    init(_ profile: Profile, isNew: Bool) {
        self.profile = profile
        self.isNew = isNew
    }
}

/// Edits a profile of any type (the design's sheet: common fields over a segmented control).
/// Fields write straight into `profile.options`, so options this editor doesn't know about
/// are preserved.
struct ProfileEditorSheet: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", ports = "Ports", advanced = "Advanced", ciphers = "Ciphers", colors = "Colours", // l10n-ignore: ids
             scripts = "Login scripts" // l10n-ignore: id
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return L("General")
            case .ports: return L("Ports")
            case .advanced: return L("Advanced")
            case .ciphers: return L("Ciphers")
            case .colors: return L("Colours")
            case .scripts: return L("Login scripts")
            }
        }
    }

    let item: EditableProfile
    let done: (Profile?) -> Void
    @State private var profile: Profile
    @State private var page: Page = .general
    @State private var passwordSaved = false
    @State private var testOutcome: SSHConnectionTest.Outcome?
    @State private var testing = false
    @Environment(\.chrome) private var chrome

    init(item: EditableProfile, initialPage: Page = .general, done: @escaping (Profile?) -> Void) {
        self.item = item
        self.done = done
        _profile = State(initialValue: item.profile)
        _page = State(initialValue: initialPage)
    }

    private var isSSH: Bool { profile.type == "ssh" }

    private var pages: [Page] { Self.pages(for: profile.type) }

    static func pages(for type: String) -> [Page] {
        type == "ssh" ? Page.allCases : [.general, .advanced, .colors, .scripts]
    }

    enum DeviceMenuEntry: Equatable {
        case port(title: String, path: String)
        case separator
    }

    /// The Device menu (design C6a): external ports with Tabby's description, then the Mac's
    /// own ports after a separator.
    static func deviceMenu(ports: [SerialPortInfo]) -> [DeviceMenuEntry] {
        func entry(_ port: SerialPortInfo) -> DeviceMenuEntry {
            .port(title: port.description.map { "\(port.deviceName) (\($0))" } ?? port.deviceName, path: port.path)
        }
        let external = ports.filter { !$0.isInternal }.map(entry)
        let builtIn = ports.filter(\.isInternal).map(entry)
        return external + (external.isEmpty || builtIn.isEmpty ? [] : [.separator]) + builtIn
    }

    /// Whether the type connects somewhere (and so has service messages to clear).
    private var isConnection: Bool { ["ssh", "serial", "telnet"].contains(profile.type) }

    /// A stream-processing option (`inputMode`…): "" for Tabby's null, which is stored as an
    /// explicit null so it beats a type default that isn't null (telnet's local echo, CRLF).
    private func modeOption(_ key: String) -> Binding<String> {
        Binding(get: { Self.effectiveOption(profile, key) },
                set: { profile.options[key] = $0.isEmpty ? .null : .string($0) })
    }

    /// Options whose null means something ("Normal", "Keep") and is kept when saving.
    static let meaningfulNulls: Set<String> = ["inputMode", "outputMode", "inputNewlines", "outputNewlines"]

    /// The value an option has once the type's defaults apply ("" for null).
    static func effectiveOption(_ profile: Profile, _ key: String) -> String {
        if let value = profile.options[key] { return value.stringValue ?? "" }
        return AppServices.shared.profiles.resolved(profile).options[key]?.stringValue ?? ""
    }

    /// The profile as saved: named by its provider when unnamed, empty values dropped except
    /// the ones whose null overrides a default.
    static func finalized(_ profile: Profile) -> Profile {
        var p = named(profile)
        if var o = p.options.objectValue {
            for (k, v) in o where v.isNull && !meaningfulNulls.contains(k) { o[k] = nil }
            p.options = .object(o)
        }
        return p
    }

    private func option(_ key: String) -> Binding<String> {
        Binding(get: { profile.options[key]?.stringValue ?? "" },
                set: { profile.options[key] = $0.isEmpty ? .null : .string($0) })
    }

    private func intOption(_ key: String, default value: Int) -> Binding<Int> {
        Binding(get: { profile.options[key]?.intValue ?? value }, set: { profile.options[key] = .int($0) })
    }

    private func boolOption(_ key: String, default value: Bool = false) -> Binding<Bool> {
        Binding(get: { profile.options[key]?.boolValue ?? value }, set: { profile.options[key] = .bool($0) })
    }

    /// A number that may be left empty (stored as an integer, removed when empty).
    private func optionalIntOption(_ key: String) -> Binding<String> {
        Binding(get: { profile.options[key]?.intValue.map(String.init) ?? "" },
                set: { text in
                    let digits = text.filter(\.isNumber)
                    profile.options[key] = Int(digits).map { .int($0) } ?? .null
                })
    }

    /// `options.input.backspace` (Tabby's input processing), "backspace" when unset.
    private var backspaceOption: Binding<String> {
        Binding(get: { InputProcessing.backspaceMode(profile.options) ?? "backspace" },
                set: { mode in
                    var input = profile.options["input"]?.objectValue ?? [:]
                    input["backspace"] = .string(mode)
                    profile.options["input"] = .object(input)
                })
    }

    /// One `options.algorithms` list as comma-separated names; empty uses the defaults.
    private func algorithmOption(_ kind: String) -> Binding<String> {
        Binding(get: { (profile.options["algorithms"]?[kind]?.stringArrayValue ?? []).joined(separator: ",") },
                set: { text in
                    var algorithms = profile.options["algorithms"]?.objectValue ?? [:]
                    let list = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    algorithms[kind] = list.isEmpty ? nil : .array(list.map { .string($0) })
                    profile.options["algorithms"] = algorithms.isEmpty ? .null : .object(algorithms)
                })
    }

    private func listOption(_ key: String) -> Binding<String> {
        Binding(get: { (profile.options[key]?.stringArrayValue ?? []).joined(separator: "\n") },
                set: { profile.options[key] = .array($0.split(separator: "\n").map { .string(String($0)) }) })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    common
                    Picker("", selection: $page) { ForEach(pages) { Text($0.title).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    switch page {
                    case .general: generalPage
                    case .ports: AnyView(SettingsGroup(L("Forwarded ports")) { PortForwardsEditor(options: $profile.options) })
                    case .advanced: advancedPage
                    case .ciphers: AnyView(sshCiphers)
                    case .colors: AnyView(colours)
                    case .scripts: AnyView(LoginScriptsEditor(options: $profile.options))
                    }
                }
                .padding(20)
            }
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            HStack {
                Spacer()
                Button(L("Cancel")) { done(nil) }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Button(item.isNew ? L("Create") : L("Save")) { done(finalProfile()) }
                    .buttonStyle(ChromeButtonStyle(kind: .primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(["ssh", "telnet"].contains(profile.type) && (profile.options["host"]?.stringValue ?? "").isEmpty)
            }
            .padding(14)
        }
        .frame(width: 640, height: 660)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .onAppear(perform: refreshPasswordState)
    }

    private var header: some View {
        HStack(spacing: 12) {
            // The profile's colour behind its icon at 20% (design C6/C7).
            let tint = profile.color.flatMap(RGBColor.init(hex:)) ?? chrome.accent
            Image(systemName: ProfileIcons.symbol(for: profile.icon ?? ProfileIcons.defaultIcon(forType: profile.type)))
                .font(.system(size: 20))
                .foregroundStyle(tint.color)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 9).fill(tint.withAlpha(0.2).color))
            VStack(alignment: .leading, spacing: 2) {
                TextField(namePlaceholder, text: $profile.name)
                    .textFieldStyle(.plain).font(ChromeFont.headline)
                Text(ProfileTypes.title(profile.type)).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(chrome.separator.color).frame(height: 1) }
    }

    private var common: some View {
        let registry = AppServices.shared.profiles
        return SettingsGroup {
            SettingsRow(L("Group")) {
                HStack(spacing: 6) {
                    RowPicker(selection: Binding(get: { profile.group ?? "" }, set: { profile.group = $0.isEmpty ? nil : $0 })) {
                        Text(L("None")).tag("")
                        ForEach(registry.groups, id: \.id) { g in Text(registry.groupPath(g.id)).tag(g.id) }
                    }
                    IconButton(symbol: "folder.badge.plus", help: L("New group"), size: 24) {
                        Prompts.text(in: NSApp.keyWindow, title: L("New group"), confirm: L("Create")) { name, _ in
                            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
                            if let g = registry.groups.first(where: { $0.name == name }) {
                                profile.group = g.id
                            } else {
                                let g = ProfileGroup(name: name)
                                registry.save(g)
                                profile.group = g.id
                            }
                        }
                    }
                }
            }
            SettingsRow(L("Icon & colour")) {
                HStack(spacing: 8) {
                    RowPicker(selection: Binding(get: { profile.icon ?? "" }, set: { profile.icon = $0.isEmpty ? nil : $0 })) {
                        Text(L("Default")).tag("")
                        ForEach(ProfileIcons.choices, id: \.self) { name in Label(name, systemImage: ProfileIcons.symbol(for: name)).tag(name) }
                    }
                    ColourSwatches(selection: $profile.color)
                }
            }
            SettingsRow(L("When the session ends")) {
                RowSegments(selection: $profile.behaviorOnSessionEnd) {
                    Text(L("Auto")).tag(SessionEndBehavior.auto)
                    Text(L("Keep")).tag(SessionEndBehavior.keep)
                    Text(L("Reconnect")).tag(SessionEndBehavior.reconnect)
                    Text(L("Close")).tag(SessionEndBehavior.close)
                }
            }
            if isConnection {
                SettingsRow(L("Clear terminal after connection"), subtitle: L("Removes the connection messages once connected"),
                            isOn: $profile.clearServiceMessagesOnConnect)
            }
        }
    }

    private var namePlaceholder: String {
        switch profile.type {
        case "ssh": return "user@host:port"
        case "telnet": return "host:port"
        case "serial": return L("Device name")
        default: return L("Name")
        }
    }

    private var generalPage: AnyView {
        switch profile.type {
        case "ssh": return AnyView(sshGeneral)
        case "serial": return AnyView(serialGeneral)
        case "telnet": return AnyView(telnetGeneral)
        default: return AnyView(localGeneral)
        }
    }

    private var advancedPage: AnyView {
        switch profile.type {
        case "ssh": return AnyView(sshAdvanced)
        case "serial": return AnyView(serialAdvanced)
        case "telnet": return AnyView(telnetAdvanced)
        default: return AnyView(localAdvanced)
        }
    }

    // MARK: Serial and telnet (Tabby's serialProfileSettings / telnetProfileSettings)

    private var serialGeneral: some View {
        let ports = AppServices.shared.serialPorts.ports
        return VStack(alignment: .leading, spacing: 18) {
            SettingsGroup(footer: L("Without a device or a baud rate, Tabby asks each time the profile opens.")) {
                SettingsRow(L("Device")) {
                    HStack(spacing: 6) {
                        RowField(placeholder: L("Ask every time"), text: option("port"), width: 300)
                        Menu {
                            let entries = Self.deviceMenu(ports: ports)
                            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                                switch entry {
                                case let .port(title, path):
                                    Button(title) { profile.options["port"] = .string(path) }
                                case .separator:
                                    Divider()
                                }
                            }
                            if entries.isEmpty { Text(L("No serial ports found")) }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
                SettingsRow(L("Baud rate")) {
                    HStack(spacing: 6) {
                        RowField(placeholder: L("Ask every time"), text: optionalIntOption("baudrate"), width: 180)
                        Menu {
                            Button(L("Ask every time")) { profile.options["baudrate"] = .null }
                            ForEach(BaudRates.standard, id: \.self) { rate in
                                Button(String(rate)) { profile.options["baudrate"] = .int(rate) }
                            }
                        } label: { Image(systemName: "chevron.up.chevron.down") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
            streamProcessing
        }
    }

    private var serialAdvanced: some View {
        SettingsGroup {
            SettingsRow(L("Data bits")) {
                RowSegments(selection: intOption("databits", default: 8)) {
                    ForEach([5, 6, 7, 8], id: \.self) { Text(String($0)).tag($0) }
                }
            }
            SettingsRow(L("Stop bits")) {
                RowSegments(selection: Binding(get: { profile.options["stopbits"]?.doubleValue ?? 1 },
                                             set: { profile.options["stopbits"] = $0 == 1.5 ? .double($0) : .int(Int($0)) })) {
                    Text("1").tag(1.0)
                    Text("1.5").tag(1.5)
                    Text("2").tag(2.0)
                }
            }
            SettingsRow(L("Parity")) {
                RowSegments(selection: Binding(get: { profile.options["parity"]?.stringValue ?? "none" },
                                             set: { profile.options["parity"] = .string($0) })) {
                    Text(L("None")).tag("none")
                    Text(L("Even")).tag("even")
                    Text(L("Odd")).tag("odd")
                }
            }
            SettingsRow(L("RTS / CTS"), isOn: boolOption("rtscts"))
            SettingsRow(L("XON"), isOn: boolOption("xon"))
            SettingsRow(L("XOFF"), isOn: boolOption("xoff"))
            SettingsRow(L("Xany"), isOn: boolOption("xany"))
            SettingsRow(L("Slow feed"), subtitle: L("Sends data one byte at a time"), isOn: boolOption("slowSend"))
            backspaceRow
            SettingsRow(L("Ignore titles set by programs"), isOn: $profile.disableDynamicTitle)
        }
    }

    private var telnetGeneral: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow(L("Host")) {
                    HStack(spacing: 8) {
                        RowField(placeholder: "example.com", text: option("host"), width: 300) // l10n-ignore: sample input
                        Text(L("Port")).foregroundStyle(chrome.textMuted.color).fixedSize()
                        TextField("23", value: intOption("port", default: 23), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).font(.custom("Menlo", size: 12)).frame(width: 56)
                    }
                }
            }
            streamProcessing
        }
    }

    private var telnetAdvanced: some View {
        SettingsGroup {
            backspaceRow
            SettingsRow(L("Ignore titles set by programs"), isOn: $profile.disableDynamicTitle)
        }
    }

    /// Tabby's stream-processing settings, with its names and descriptions.
    private var streamProcessing: some View {
        SettingsGroup(L("Stream processing")) {
            SettingsRow(L("Input mode"), subtitle: StreamModeNames.inputDescription(Self.effectiveOption(profile, "inputMode"))) {
                RowPicker(selection: modeOption("inputMode")) {
                    ForEach(StreamModeNames.inputModes, id: \.value) { Text($0.name).tag($0.value) }
                }
            }
            SettingsRow(L("Output mode"), subtitle: StreamModeNames.outputDescription(Self.effectiveOption(profile, "outputMode"))) {
                RowPicker(selection: modeOption("outputMode")) {
                    ForEach(StreamModeNames.outputModes, id: \.value) { Text($0.name).tag($0.value) }
                }
            }
            SettingsRow(L("Input newlines")) {
                RowPicker(selection: modeOption("inputNewlines")) {
                    ForEach(StreamModeNames.newlineModes, id: \.value) { Text($0.name).tag($0.value) }
                }
            }
            SettingsRow(L("Output newlines")) {
                RowPicker(selection: modeOption("outputNewlines")) {
                    ForEach(StreamModeNames.newlineModes, id: \.value) { Text($0.name).tag($0.value) }
                }
            }
        }
    }

    private var backspaceRow: some View {
        SettingsRow(L("Backspace sends")) {
            RowPicker(selection: backspaceOption) {
                Text(L("Backspace (DEL)")).tag("backspace")
                Text(L("Ctrl-H")).tag("ctrl-h")
                Text(L("Ctrl-?")).tag("ctrl-?")
                Text(L("Delete (ESC [3~)")).tag("delete")
            }
        }
    }

    private var localGeneral: some View {
        SettingsGroup {
            SettingsRow(L("Command")) { RowField(placeholder: "/bin/zsh", text: option("command"), width: 300) } // l10n-ignore: sample input
            SettingsRow(L("Arguments"), subtitle: L("One per line")) {
                TextEditor(text: listOption("args")).font(.custom("Menlo", size: 12)).frame(width: 300, height: 54)
                    .scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 5).fill(chrome.surface.color))
            }
            SettingsRow(L("Working directory")) { RowField(placeholder: L("Inherit"), text: option("cwd"), width: 300) }
        }
    }

    private var localAdvanced: some View {
        SettingsGroup {
            SettingsRow(L("Keep the tab open after the process exits"), isOn: boolOption("pauseAfterExit"))
            SettingsRow(L("Ignore titles set by programs"), isOn: $profile.disableDynamicTitle)
        }
    }

    private var sshGeneral: some View {
        let registry = AppServices.shared.profiles
        return VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow(L("Host")) {
                    HStack(spacing: 8) {
                        RowField(placeholder: "example.com", text: option("host"), width: 220) // l10n-ignore: sample input
                        Text(L("Port")).foregroundStyle(chrome.textMuted.color).fixedSize()
                        TextField("22", value: intOption("port", default: 22), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).font(.custom("Menlo", size: 12)).frame(width: 60)
                    }
                }
                SettingsRow(L("Username")) { RowField(placeholder: NSUserName(), text: option("user")) }
                SettingsRow(L("Authentication")) {
                    RowPicker(selection: option("auth")) {
                        Text(L("Automatic")).tag("")
                        Text(L("Password")).tag("password")
                        Text(L("Public key")).tag("publicKey")
                        Text(L("Agent")).tag("agent")
                        Text(L("Keyboard-interactive")).tag("keyboardInteractive")
                    }
                }
                SettingsRow(L("Password"), subtitle: passwordSaved ? L("Saved in Keychain") : L("Asked for when connecting")) {
                    HStack(spacing: 6) {
                        Button(passwordSaved ? "Change…" : "Set…") { setPassword() }.buttonStyle(ChromeButtonStyle())
                            .disabled((profile.options["host"]?.stringValue ?? "").isEmpty)
                        if passwordSaved {
                            Button(L("Forget")) { forgetPassword() }.buttonStyle(ChromeButtonStyle(kind: .plain))
                        }
                    }
                }
            }
            SettingsGroup(L("Private keys")) {
                PrivateKeysEditor(options: $profile.options)
            }
            SettingsGroup {
                SettingsRow(L("Jump host")) {
                    RowPicker(selection: option("jumpHost")) {
                        Text(L("None")).tag("")
                        ForEach(registry.allProfiles(includeHidden: true).filter { $0.type == "ssh" && !$0.isTemplate && $0.id != profile.id }, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                }
                SettingsRow(L("Proxy command")) { RowField(placeholder: L("None"), text: option("proxyCommand"), width: 300) }
            }
            SettingsGroup {
                SettingsRow(L("Test connection"), subtitle: testSubtitle) {
                    HStack(spacing: 8) {
                        if testing { ProgressView().controlSize(.small) }
                        Button { testConnection() } label: { Label(L("Test connection"), systemImage: "bolt") }
                            .buttonStyle(ChromeButtonStyle())
                            .disabled(testing || (profile.options["host"]?.stringValue ?? "").isEmpty)
                    }
                }
            }
        }
    }

    private var testSubtitle: String {
        switch testOutcome {
        case .success(let text)?: return text
        case .failure(let text)?: return L("Failed: {text}", ["text": text])
        case nil: return L("Connects and logs in with these values; no shell is opened")
        }
    }

    /// Prompts attach to this sheet (a second sheet on the main window would wait behind it).
    private func testConnection() {
        testing = true
        testOutcome = nil
        let services = AppServices.shared
        let resolved = services.profiles.resolved(finalProfile())
        let prompter = WindowPrompter(window: NSApp.keyWindow)
        Task {
            testOutcome = await SSHConnectionTest.run(profile: resolved, connector: services.libSSHFactory.connector, prompter: prompter)
            testing = false
        }
    }

    /// Algorithm preferences, sent as written (Tabby sorted them alphabetically, which
    /// changed the preference order).
    private var sshCiphers: some View {
        SettingsGroup(footer: L("Comma-separated, most preferred first. Empty uses the defaults.")) {
            SettingsRow(L("Key exchange")) { RowField(placeholder: L("Default"), text: algorithmOption("kex"), width: 320) }
            SettingsRow(L("Host key")) { RowField(placeholder: L("Default"), text: algorithmOption("serverHostKey"), width: 320) }
            SettingsRow(L("Ciphers")) { RowField(placeholder: L("Default"), text: algorithmOption("cipher"), width: 320) }
            SettingsRow(L("MACs")) { RowField(placeholder: L("Default"), text: algorithmOption("hmac"), width: 320) }
            SettingsRow(L("Compression")) { RowField(placeholder: L("Default"), text: algorithmOption("compression"), width: 320) }
        }
    }

    private var sshAdvanced: some View {
        SettingsGroup {
            SettingsRow(L("Agent forwarding"), isOn: boolOption("agentForward"))
            SettingsRow(L("X11 forwarding"), isOn: boolOption("x11"))
            SettingsRow(L("Reuse the connection for new tabs"), isOn: boolOption("reuseSession", default: true))
            SettingsRow(L("Skip the login banner"), isOn: boolOption("skipBanner"))
            SettingsRow(L("Ignore titles set by programs"), isOn: $profile.disableDynamicTitle)
            SettingsRow(L("Keep-alive interval"), subtitle: L("Milliseconds")) {
                TextField("5000", value: intOption("keepaliveInterval", default: 5000), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).font(.custom("Menlo", size: 12)).frame(width: 90)
            }
            SettingsRow(L("Keep-alive count"), subtitle: L("Unanswered keep-alives before the connection counts as lost")) {
                TextField("10", value: intOption("keepaliveCountMax", default: 10), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).font(.custom("Menlo", size: 12)).frame(width: 90)
            }
            SettingsRow(L("Ready timeout"), subtitle: L("Milliseconds to wait for the connection; empty waits as long as the system does")) {
                RowField(placeholder: L("Default"), text: optionalIntOption("readyTimeout"), width: 90)
            }
            backspaceRow
            SettingsRow(L("Terminal type")) { RowField(placeholder: "xterm-256color", text: option("term")) } // l10n-ignore: sample input
            SettingsRow(L("Start in directory")) { RowField(placeholder: L("Home"), text: option("cwd")) }
            SettingsRow(L("Reopen in the last directory"), subtitle: L("When the tab is restored; the remote shell must report it (OSC 7)"),
                        isOn: boolOption("rememberCwd"))
        }
    }

    private var colours: some View {
        let services = AppServices.shared
        let all = services.schemes.all(custom: ColorSchemeCatalog.customSchemes(from: services.config))
        let current = ColorScheme(config: profile.terminalColorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: L("Overrides the colour scheme for this profile's tabs.")) {
                SettingsRow(L("Colour scheme")) {
                    RowPicker(selection: Binding(get: { current?.name ?? "" }, set: { name in
                        profile.terminalColorScheme = all.first { $0.name == name }.map { s in
                            var v = s.configValue
                            v[ConfigValue.nonStructuralKey] = nil
                            return v
                        }
                    })) {
                        Text(L("Use the global scheme")).tag("")
                        ForEach(all, id: \.name) { Text($0.name).tag($0.name) }
                    }
                }
            }
            if let current { SchemePreview(scheme: current) }
        }
    }

    private var keyFor: (host: String, port: Int, user: String) {
        (profile.options["host"]?.stringValue ?? "", profile.options["port"]?.intValue ?? 22,
         profile.options["user"]?.stringValue ?? NSUserName())
    }

    private func refreshPasswordState() {
        guard isSSH else { return }
        let k = keyFor
        passwordSaved = !k.host.isEmpty && AppServices.shared.passwords.hasPassword(host: k.host, port: k.port, user: k.user)
    }

    private func setPassword() {
        let k = keyFor
        Prompts.text(in: NSApp.keyWindow, title: L("Password for {user}@{host}", ["user": k.user, "host": k.host]), message: L("Saved in the login keychain."),
                     secure: true, confirm: L("Save")) { value, _ in
            guard let value, !value.isEmpty else { return }
            AppServices.shared.passwords.savePassword(value, host: k.host, port: k.port, user: k.user)
            refreshPasswordState()
        }
    }

    private func forgetPassword() {
        let k = keyFor
        Prompts.confirm(in: NSApp.keyWindow, title: L("Forget the password for {user}@{host}?", ["user": k.user, "host": k.host]),
                        message: L("It is removed from the Keychain here and, when passwords sync, on your other Macs."),
                        confirm: L("Forget"), destructive: true) { ok in
            guard ok else { return }
            AppServices.shared.passwords.deletePassword(host: k.host, port: k.port, user: k.user)
            refreshPasswordState()
        }
    }

    /// An empty name becomes what the type's provider suggests (`user@host`, `host:port`, the
    /// device path), as Tabby's `getSuggestedName`.
    static func named(_ profile: Profile) -> Profile {
        var p = profile
        if p.name.isEmpty, let suggested = AppServices.shared.profiles.provider(for: p.type)?.suggestedName(for: p) {
            p.name = suggested
        }
        return p
    }

    private func finalProfile() -> Profile { Self.finalized(profile) }
}

/// The design's colour swatches: none plus the scheme's six ANSI colours, stored as hex as in
/// Tabby.
private struct ColourSwatches: View {
    @Binding var selection: String?
    @Environment(\.chrome) private var chrome

    var body: some View {
        let palette = AppServices.shared.theme.scheme.paletteRGB
        let colours = [1, 3, 2, 6, 4, 5].map { palette[$0].hex }
        HStack(spacing: 5) {
            Button { selection = nil } label: {
                Image(systemName: "nosign").font(.system(size: 13)).foregroundStyle(chrome.textMuted.color)
            }
            .buttonStyle(.plain)
            .help(L("No colour"))
            ForEach(colours, id: \.self) { hex in
                Button { selection = hex } label: {
                    Circle().fill((RGBColor(hex: hex) ?? .black).color).frame(width: 15, height: 15)
                        .overlay(Circle().strokeBorder(selection?.lowercased() == hex ? chrome.text.color : .clear, lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Key files of an SSH profile, added with an open panel.
private struct PrivateKeysEditor: View {
    @Binding var options: ConfigValue
    @Environment(\.chrome) private var chrome

    var body: some View {
        let keys = options["privateKeys"]?.stringArrayValue ?? []
        ForEach(Array(keys.enumerated()), id: \.offset) { index, path in
            SettingsRow((path as NSString).abbreviatingWithTildeInPath) {
                IconButton(symbol: "minus", help: L("Remove"), size: 22) {
                    var list = keys
                    list.remove(at: index)
                    options["privateKeys"] = .array(list.map { .string($0) })
                }
            }
        }
        SettingsRow(keys.isEmpty ? L("No keys: ssh tries the agent and its default identities") : L("Add another key")) {
            Button(L("Add key…")) {
                let panel = NSOpenPanel()
                panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
                panel.showsHiddenFiles = true
                panel.allowsMultipleSelection = true
                guard panel.runModal() == .OK else { return }
                let list = keys + panel.urls.map(\.path).filter { !keys.contains($0) }
                options["privateKeys"] = .array(list.map { .string($0) })
            }
            .buttonStyle(ChromeButtonStyle())
        }
    }
}

/// Editable forwarded ports: type, local address and port, and the target.
struct PortForwardsEditor: View {
    @Binding var options: ConfigValue
    @Environment(\.chrome) private var chrome

    var body: some View {
        let forwards = (options["forwardedPorts"]?.arrayValue ?? []).compactMap(ForwardedPort.init)
        ForEach(Array(forwards.enumerated()), id: \.offset) { index, f in
            HStack(spacing: 6) {
                RowPicker(selection: binding(forwards, index, \.type)) {
                    ForEach(PortForwardType.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("127.0.0.1", text: binding(forwards, index, \.host)).frame(width: 96)
                TextField("8080", value: binding(forwards, index, \.port), format: .number.grouping(.never)).frame(width: 56)
                if f.type != .dynamic {
                    Image(systemName: "arrow.right").foregroundStyle(chrome.textFaint.color)
                    TextField("localhost", text: binding(forwards, index, \.targetAddress)).frame(width: 110) // l10n-ignore: sample input
                    TextField("80", value: binding(forwards, index, \.targetPort), format: .number.grouping(.never)).frame(width: 56)
                }
                Spacer()
                IconButton(symbol: "minus", help: L("Remove"), size: 22) {
                    var list = forwards
                    list.remove(at: index)
                    options["forwardedPorts"] = .array(list.map(\.configValue))
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.custom("Menlo", size: 12))
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
        }
        SettingsRow(forwards.isEmpty ? L("No forwarded ports") : L("Forwards start with the session"),
                    subtitle: L("While connected, change them from Ports on the connection chip")) {
            Menu(L("Add forward")) {
                ForEach(PortForwardType.allCases, id: \.self) { type in
                    Button(type.title) {
                        var list = forwards
                        list.append(ForwardedPort(type: type, host: "127.0.0.1", port: 8080, targetAddress: "localhost", targetPort: 80))
                        options["forwardedPorts"] = .array(list.map(\.configValue))
                    }
                }
            }
            .fixedSize()
        }
    }

    private func binding<T>(_ forwards: [ForwardedPort], _ index: Int, _ path: WritableKeyPath<ForwardedPort, T>) -> Binding<T> {
        Binding(get: { forwards[index][keyPath: path] }, set: { value in
            var list = forwards
            list[index][keyPath: path] = value
            options["forwardedPorts"] = .array(list.map(\.configValue))
        })
    }
}

/// "When output contains … send …" rows (Tabby's login scripts).
private struct LoginScriptsEditor: View {
    @Binding var options: ConfigValue
    @Environment(\.chrome) private var chrome

    var body: some View {
        let scripts = options["scripts"]?.arrayValue ?? []
        SettingsGroup(L("Login scripts"), footer: L("When the output contains the text, TabbyMac types the reply and presses Return.")) {
            ForEach(Array(scripts.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    TextField(L("Expect"), text: field(scripts, index, "expect")).frame(width: 160)
                    Image(systemName: "arrow.right").foregroundStyle(chrome.textFaint.color)
                    TextField(L("Send"), text: field(scripts, index, "send")).frame(width: 160)
                    Toggle(L("Regex"), isOn: flag(scripts, index, "isRegex")).toggleStyle(.checkbox)
                    Toggle(L("Optional"), isOn: flag(scripts, index, "optional")).toggleStyle(.checkbox)
                    Spacer()
                    IconButton(symbol: "minus", help: L("Remove"), size: 22) {
                        var list = scripts
                        list.remove(at: index)
                        options["scripts"] = .array(list)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.custom("Menlo", size: 12))
                .padding(.horizontal, 14)
                .frame(minHeight: 40)
            }
            SettingsRow(scripts.isEmpty ? L("No login scripts") : L("Add another")) {
                Button(L("Add script")) { options["scripts"] = .array(scripts + [["expect": "", "send": ""]]) }
                    .buttonStyle(ChromeButtonStyle())
            }
        }
    }

    private func field(_ scripts: [ConfigValue], _ index: Int, _ key: String) -> Binding<String> {
        Binding(get: { scripts[index][key]?.stringValue ?? "" }, set: { v in
            var list = scripts
            list[index][key] = .string(v)
            options["scripts"] = .array(list)
        })
    }

    private func flag(_ scripts: [ConfigValue], _ index: Int, _ key: String) -> Binding<Bool> {
        Binding(get: { scripts[index][key]?.boolValue ?? false }, set: { v in
            var list = scripts
            list[index][key] = .bool(v)
            options["scripts"] = .array(list)
        })
    }
}
#endif
