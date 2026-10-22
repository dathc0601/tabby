#if canImport(AppKit)
import AppKit
import SwiftUI
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
        SettingsPage("Profiles & connections") {
            SettingsGroup {
                SettingsRow("Default profile for new tabs") {
                    RowPicker(selection: ConfigBinding.string("terminal.profile")) {
                        ForEach(registry.allProfiles(includeHidden: true).filter { !$0.isTemplate }, id: \.id) { p in Text(p.name).tag(p.id) }
                    }
                }
            }
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
                    TextField("Filter profiles", text: $filter).textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(chrome.fill.color))
                Toggle("Show hidden", isOn: $showHidden).toggleStyle(.checkbox)
                Menu {
                    Button("Local terminal") { editing = EditableProfile(Self.newLocal(), isNew: true) }
                    Button("SSH connection") { editing = EditableProfile(Self.newSSH(), isNew: true) }
                } label: {
                    Label("New", systemImage: "plus")
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
                        Text(filter.isEmpty ? "No profiles" : "No profiles match “\(filter)”")
                            .foregroundStyle(chrome.textMuted.color).padding(20)
                    }
                }
                .padding(6)
                Rectangle().fill(chrome.separator.color).frame(height: 1)
                HStack(spacing: 4) {
                    IconButton(symbol: "plus", help: "New local profile", size: 24) { editing = EditableProfile(Self.newLocal(), isNew: true) }
                    IconButton(symbol: "minus", help: "Delete profile", size: 24) { if let selected { delete(selected, registry: registry) } }
                        .disabled(selected.map { $0.isBuiltin } ?? true)
                    Rectangle().fill(chrome.separator.color).frame(width: 1, height: 16).padding(.horizontal, 4)
                    Button { if let selected { duplicate(selected) } } label: { Label("Duplicate", systemImage: "doc.on.doc") }
                        .disabled(selected == nil)
                    Button { if let selected { toggleHidden(selected, registry: registry) } } label: {
                        Label(selected?.extra["hidden"]?.boolValue == true ? "Unhide" : "Hide", systemImage: "eye.slash")
                    }
                    .disabled(selected.map { $0.isBuiltin } ?? true)
                    Button { newGroup(registry: registry) } label: { Label("New group", systemImage: "folder.badge.plus") }
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
        Button("Open in a new tab") { _ = WindowManager.shared.activeController?.model.openTab(profile: p) }
        Button("Use for new tabs") { AppServices.shared.config.set("terminal.profile", .string(p.id)) }
        Divider()
        if !p.isBuiltin { Button("Edit…") { edit(p) } }
        Button("Duplicate") { duplicate(p) }
        if !p.isBuiltin {
            Button(p.extra["hidden"]?.boolValue == true ? "Unhide" : "Hide") { toggleHidden(p, registry: registry) }
            Divider()
            Button("Delete…", role: .destructive) { delete(p, registry: registry) }
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
        Prompts.confirm(in: NSApp.keyWindow, title: "Delete “\(p.name)”?",
                        message: "The profile is removed here and, when profiles sync, on your other Macs. A password saved for it stays in the Keychain (Settings › Vault).",
                        confirm: "Delete", destructive: true) { ok in
            guard ok else { return }
            registry.delete(profileId: p.id)
            if selection == p.id { selection = nil }
        }
    }

    private func newGroup(registry: ProfileRegistry) {
        Prompts.text(in: NSApp.keyWindow, title: "New group", value: "", confirm: "Create") { name, _ in
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !registry.groups.contains(where: { $0.name == name }) else { return }
            registry.save(ProfileGroup(name: name))
        }
    }

    static func newLocal() -> Profile {
        Profile(type: "local", name: "New profile", options: LocalOptions(command: ShellDetector.loginShellName()).configValue)
    }

    static func newSSH() -> Profile {
        Profile(type: "ssh", name: "", options: ["host": "", "port": 22, "user": .string(NSUserName())])
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
            let title = p.isBuiltin ? (p.group ?? "Built-in") : (registry.groupPath(p.group).isEmpty ? "Ungrouped" : registry.groupPath(p.group))
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
            Image(systemName: ProfileIcons.symbol(for: profile.icon ?? (profile.type == "ssh" ? "server" : "terminal")))
                .foregroundStyle((isSelected ? chrome.onAccent : (tint ?? chrome.textMuted)).color)
                .frame(width: 18)
            Text(profile.name).foregroundStyle(fg.color).lineLimit(1)
            Text(description).font(ChromeFont.caption).foregroundStyle(muted.color).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if let tint { StatusDot(color: tint, size: 7) }
            if hidden { Image(systemName: "eye.slash").font(.system(size: 11)).foregroundStyle(muted.color) }
            if isDefault {
                Text("Default").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 16)
                    .foregroundStyle((isSelected ? chrome.onAccent : chrome.accent).color)
                    .background(Capsule().fill((isSelected ? chrome.onAccent.withAlpha(0.2) : chrome.accentFill).color))
            }
            Text(Self.typeLabel(profile.type)).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 6).frame(height: 16)
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

    static func typeLabel(_ type: String) -> String {
        switch type {
        case "ssh": return "SSH"
        case "local": return "Local"
        case "split-layout": return "Layout"
        default: return type.capitalized
        }
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

/// Edits a local or SSH profile (the design's sheet: common fields over a segmented control).
/// Fields write straight into `profile.options`, so options this editor doesn't know about
/// are preserved.
struct ProfileEditorSheet: View {
    enum Page: String, CaseIterable, Identifiable {
        case general = "General", ports = "Ports", advanced = "Advanced", colors = "Colours", scripts = "Login scripts"
        var id: String { rawValue }
    }

    let item: EditableProfile
    let done: (Profile?) -> Void
    @State private var profile: Profile
    @State private var page: Page = .general
    @State private var passwordSaved = false
    @Environment(\.chrome) private var chrome

    init(item: EditableProfile, initialPage: Page = .general, done: @escaping (Profile?) -> Void) {
        self.item = item
        self.done = done
        _profile = State(initialValue: item.profile)
        _page = State(initialValue: initialPage)
    }

    private var isSSH: Bool { profile.type == "ssh" }

    private var pages: [Page] {
        isSSH ? Page.allCases : [.general, .advanced, .colors, .scripts]
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
                    Picker("", selection: $page) { ForEach(pages) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    switch page {
                    case .general: isSSH ? AnyView(sshGeneral) : AnyView(localGeneral)
                    case .ports: AnyView(SettingsGroup("Forwarded ports") { PortForwardsEditor(options: $profile.options) })
                    case .advanced: isSSH ? AnyView(sshAdvanced) : AnyView(localAdvanced)
                    case .colors: AnyView(colours)
                    case .scripts: AnyView(LoginScriptsEditor(options: $profile.options))
                    }
                }
                .padding(20)
            }
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Button(item.isNew ? "Create" : "Save") { done(finalProfile()) }
                    .buttonStyle(ChromeButtonStyle(kind: .primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(isSSH && (profile.options["host"]?.stringValue ?? "").isEmpty)
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
            Image(systemName: ProfileIcons.symbol(for: profile.icon ?? (isSSH ? "server" : "terminal")))
                .font(.system(size: 18))
                .foregroundStyle((profile.color.flatMap(RGBColor.init(hex:)) ?? chrome.accent).color)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(chrome.fill.color))
            VStack(alignment: .leading, spacing: 2) {
                TextField(isSSH ? "user@host:port" : "Name", text: $profile.name)
                    .textFieldStyle(.plain).font(ChromeFont.headline)
                Text(isSSH ? "SSH connection" : "Local terminal").font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(chrome.separator.color).frame(height: 1) }
    }

    private var common: some View {
        let registry = AppServices.shared.profiles
        return SettingsGroup {
            SettingsRow("Group") {
                HStack(spacing: 6) {
                    RowPicker(selection: Binding(get: { profile.group ?? "" }, set: { profile.group = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        ForEach(registry.groups, id: \.id) { g in Text(registry.groupPath(g.id)).tag(g.id) }
                    }
                    IconButton(symbol: "folder.badge.plus", help: "New group", size: 24) {
                        Prompts.text(in: NSApp.keyWindow, title: "New group", confirm: "Create") { name, _ in
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
            SettingsRow("Icon & colour") {
                HStack(spacing: 8) {
                    RowPicker(selection: Binding(get: { profile.icon ?? "" }, set: { profile.icon = $0.isEmpty ? nil : $0 })) {
                        Text("Default").tag("")
                        ForEach(ProfileIcons.choices, id: \.self) { name in Label(name, systemImage: ProfileIcons.symbol(for: name)).tag(name) }
                    }
                    ColourSwatches(selection: $profile.color)
                }
            }
            SettingsRow("When the session ends") {
                RowSegments(selection: $profile.behaviorOnSessionEnd) {
                    Text("Auto").tag(SessionEndBehavior.auto)
                    Text("Keep").tag(SessionEndBehavior.keep)
                    Text("Reconnect").tag(SessionEndBehavior.reconnect)
                    Text("Close").tag(SessionEndBehavior.close)
                }
            }
        }
    }

    private var localGeneral: some View {
        SettingsGroup {
            SettingsRow("Command") { RowField(placeholder: "/bin/zsh", text: option("command"), width: 300) }
            SettingsRow("Arguments", subtitle: "One per line") {
                TextEditor(text: listOption("args")).font(.custom("Menlo", size: 12)).frame(width: 300, height: 54)
                    .scrollContentBackground(.hidden).background(RoundedRectangle(cornerRadius: 5).fill(chrome.surface.color))
            }
            SettingsRow("Working directory") { RowField(placeholder: "Inherit", text: option("cwd"), width: 300) }
        }
    }

    private var localAdvanced: some View {
        SettingsGroup {
            SettingsRow("Keep the tab open after the process exits", isOn: boolOption("pauseAfterExit"))
            SettingsRow("Ignore titles set by programs", isOn: $profile.disableDynamicTitle)
        }
    }

    private var sshGeneral: some View {
        let registry = AppServices.shared.profiles
        return VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow("Host") {
                    HStack(spacing: 8) {
                        RowField(placeholder: "example.com", text: option("host"), width: 220)
                        Text("Port").foregroundStyle(chrome.textMuted.color).fixedSize()
                        TextField("22", value: intOption("port", default: 22), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).font(.custom("Menlo", size: 12)).frame(width: 60)
                    }
                }
                SettingsRow("Username") { RowField(placeholder: NSUserName(), text: option("user")) }
                SettingsRow("Authentication") {
                    RowPicker(selection: option("auth")) {
                        Text("Automatic").tag("")
                        Text("Password").tag("password")
                        Text("Public key").tag("publicKey")
                        Text("Agent").tag("agent")
                        Text("Keyboard-interactive").tag("keyboardInteractive")
                    }
                }
                SettingsRow("Password", subtitle: passwordSaved ? "Saved in Keychain" : "Asked for when connecting") {
                    HStack(spacing: 6) {
                        Button(passwordSaved ? "Change…" : "Set…") { setPassword() }.buttonStyle(ChromeButtonStyle())
                            .disabled((profile.options["host"]?.stringValue ?? "").isEmpty)
                        if passwordSaved {
                            Button("Forget") { forgetPassword() }.buttonStyle(ChromeButtonStyle(kind: .plain))
                        }
                    }
                }
            }
            SettingsGroup("Private keys") {
                PrivateKeysEditor(options: $profile.options)
            }
            SettingsGroup {
                SettingsRow("Jump host") {
                    RowPicker(selection: option("jumpHost")) {
                        Text("None").tag("")
                        ForEach(registry.allProfiles(includeHidden: true).filter { $0.type == "ssh" && !$0.isTemplate && $0.id != profile.id }, id: \.id) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                }
                SettingsRow("Proxy command") { RowField(placeholder: "None", text: option("proxyCommand"), width: 300) }
            }
        }
    }

    private var sshAdvanced: some View {
        SettingsGroup {
            SettingsRow("Agent forwarding", isOn: boolOption("agentForward"))
            SettingsRow("X11 forwarding", isOn: boolOption("x11"))
            SettingsRow("Reuse the connection for new tabs", isOn: boolOption("reuseSession", default: true))
            SettingsRow("Skip the login banner", isOn: boolOption("skipBanner"))
            SettingsRow("Ignore titles set by programs", isOn: $profile.disableDynamicTitle)
            SettingsRow("Keep-alive interval", subtitle: "Milliseconds") {
                TextField("5000", value: intOption("keepaliveInterval", default: 5000), format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).font(.custom("Menlo", size: 12)).frame(width: 90)
            }
            SettingsRow("Terminal type") { RowField(placeholder: "xterm-256color", text: option("term")) }
            SettingsRow("Start in directory") { RowField(placeholder: "Home", text: option("cwd")) }
        }
    }

    private var colours: some View {
        let services = AppServices.shared
        let all = services.schemes.all(custom: ColorSchemeCatalog.customSchemes(from: services.config))
        let current = ColorScheme(config: profile.terminalColorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(footer: "Overrides the colour scheme for this profile's tabs.") {
                SettingsRow("Colour scheme") {
                    RowPicker(selection: Binding(get: { current?.name ?? "" }, set: { name in
                        profile.terminalColorScheme = all.first { $0.name == name }.map { s in
                            var v = s.configValue
                            v[ConfigValue.nonStructuralKey] = nil
                            return v
                        }
                    })) {
                        Text("Use the global scheme").tag("")
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
        Prompts.text(in: NSApp.keyWindow, title: "Password for \(k.user)@\(k.host)", message: "Saved in the login keychain.",
                     secure: true, confirm: "Save") { value, _ in
            guard let value, !value.isEmpty else { return }
            AppServices.shared.passwords.savePassword(value, host: k.host, port: k.port, user: k.user)
            refreshPasswordState()
        }
    }

    private func forgetPassword() {
        let k = keyFor
        Prompts.confirm(in: NSApp.keyWindow, title: "Forget the password for \(k.user)@\(k.host)?",
                        message: "It is removed from the Keychain here and, when passwords sync, on your other Macs.",
                        confirm: "Forget", destructive: true) { ok in
            guard ok else { return }
            AppServices.shared.passwords.deletePassword(host: k.host, port: k.port, user: k.user)
            refreshPasswordState()
        }
    }

    private func finalProfile() -> Profile {
        var p = profile
        if p.type == "ssh" && p.name.isEmpty {
            p.name = SSHOptions(p.options).suggestedName
        }
        // Drop empty optional values so config.yaml stays tidy.
        if var o = p.options.objectValue {
            for (k, v) in o where v.isNull { o[k] = nil }
            p.options = .object(o)
        }
        return p
    }
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
            .help("No colour")
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
                IconButton(symbol: "minus", help: "Remove", size: 22) {
                    var list = keys
                    list.remove(at: index)
                    options["privateKeys"] = .array(list.map { .string($0) })
                }
            }
        }
        SettingsRow(keys.isEmpty ? "No keys: ssh tries the agent and its default identities" : "Add another key") {
            Button("Add key…") {
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
                    ForEach(PortForwardType.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                TextField("127.0.0.1", text: binding(forwards, index, \.host)).frame(width: 96)
                TextField("8080", value: binding(forwards, index, \.port), format: .number.grouping(.never)).frame(width: 56)
                if f.type != .dynamic {
                    Image(systemName: "arrow.right").foregroundStyle(chrome.textFaint.color)
                    TextField("localhost", text: binding(forwards, index, \.targetAddress)).frame(width: 110)
                    TextField("80", value: binding(forwards, index, \.targetPort), format: .number.grouping(.never)).frame(width: 56)
                }
                Spacer()
                IconButton(symbol: "minus", help: "Remove", size: 22) {
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
        SettingsRow(forwards.isEmpty ? "No forwarded ports" : "Forwards start with the session",
                    subtitle: "While connected, change them from Ports on the connection chip") {
            Menu("Add forward") {
                ForEach(PortForwardType.allCases, id: \.self) { type in
                    Button(type.rawValue.capitalized) {
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
        SettingsGroup("Login scripts", footer: "When the output contains the text, TabbyMac types the reply and presses Return.") {
            ForEach(Array(scripts.enumerated()), id: \.offset) { index, _ in
                HStack(spacing: 6) {
                    TextField("Expect", text: field(scripts, index, "expect")).frame(width: 160)
                    Image(systemName: "arrow.right").foregroundStyle(chrome.textFaint.color)
                    TextField("Send", text: field(scripts, index, "send")).frame(width: 160)
                    Toggle("Regex", isOn: flag(scripts, index, "isRegex")).toggleStyle(.checkbox)
                    Toggle("Optional", isOn: flag(scripts, index, "optional")).toggleStyle(.checkbox)
                    Spacer()
                    IconButton(symbol: "minus", help: "Remove", size: 22) {
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
            SettingsRow(scripts.isEmpty ? "No login scripts" : "Add another") {
                Button("Add script") { options["scripts"] = .array(scripts + [["expect": "", "send": ""]]) }
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
