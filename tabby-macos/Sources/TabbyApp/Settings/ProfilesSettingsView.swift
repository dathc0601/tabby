#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbyTerminal

/// Profiles & connections (Tabby's `ProfilesSettingsTabComponent` + `EditProfileModal`).
struct ProfilesSettingsView: View {
    @State private var editing: EditableProfile?
    @State private var filter = ""

    var body: some View {
        let services = AppServices.shared
        let _ = services.configRevision
        let registry = services.profiles
        let defaultId = services.config.string("terminal.profile") ?? "local:default"
        let all = FuzzyMatcher.filter(registry.allProfiles(includeHidden: true), query: filter) { "\($0.name) \(registry.groupPath($0.group))" }
        VStack(alignment: .leading) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Menu("New profile") {
                    Button("Local terminal") {
                        editing = EditableProfile(Profile(type: "local", name: "New profile", options: LocalOptions(command: ShellDetector.loginShellName()).configValue), isNew: true)
                    }
                    Button("SSH connection") {
                        editing = EditableProfile(Profile(type: "ssh", name: "", options: ["host": "", "port": 22, "user": .string(NSUserName())]), isNew: true)
                    }
                }
                .fixedSize()
            }
            List {
                ForEach(groupedSections(all, registry: registry)) { section in
                    Section(section.title) {
                        ForEach(section.profiles, id: \.id) { p in
                            ProfileRow(profile: p, isDefault: p.id == defaultId, registry: registry,
                                       edit: { editing = EditableProfile(p, isNew: false) },
                                       duplicate: {
                                           var copy = p
                                           copy.id = ""
                                           copy.isBuiltin = false
                                           copy.name = p.name + " (copy)"
                                           editing = EditableProfile(copy, isNew: true)
                                       },
                                       makeDefault: { services.config.set("terminal.profile", .string(p.id)) },
                                       open: { _ = WindowManager.shared.activeController?.model.openTab(profile: p) })
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(item: $editing) { item in
            ProfileEditorSheet(item: item) { result in
                editing = nil
                if let result { registry.save(result) }
            }
        }
    }

    struct ProfileSection: Identifiable {
        let title: String
        let profiles: [Profile]
        var id: String { title }
    }

    private func groupedSections(_ profiles: [Profile], registry: ProfileRegistry) -> [ProfileSection] {
        var order: [String] = []
        var map: [String: [Profile]] = [:]
        for p in profiles where !p.isTemplate {
            let title = p.isBuiltin ? (p.group ?? "Built-in") : (registry.groupPath(p.group).isEmpty ? "Ungrouped" : registry.groupPath(p.group))
            if map[title] == nil { order.append(title) }
            map[title, default: []].append(p)
        }
        return order.map { ProfileSection(title: $0, profiles: map[$0] ?? []) }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let isDefault: Bool
    let registry: ProfileRegistry
    let edit: () -> Void
    let duplicate: () -> Void
    let makeDefault: () -> Void
    let open: () -> Void

    var body: some View {
        HStack {
            Image(systemName: ProfileIcons.symbol(for: profile.icon ?? (profile.type == "ssh" ? "network" : "terminal")))
                .frame(width: 20)
                .foregroundStyle(profile.color.flatMap(RGBColor.init(hex:))?.color ?? .secondary)
            VStack(alignment: .leading) {
                HStack {
                    Text(profile.name)
                    if isDefault { Text("Default").font(.caption2).padding(.horizontal, 4).background(Color.accentColor.opacity(0.2), in: Capsule()) }
                }
                Text(registry.provider(for: profile.type)?.description(for: profile) ?? profile.type)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open", action: open).buttonStyle(.borderless)
            if profile.isBuiltin {
                Button("Duplicate", action: duplicate).buttonStyle(.borderless)
            } else {
                Button("Edit", action: edit).buttonStyle(.borderless)
            }
            Menu {
                Button("Use for new tabs", action: makeDefault)
                Button("Duplicate", action: duplicate)
                if !profile.isBuiltin {
                    Button("Delete", role: .destructive) { registry.delete(profileId: profile.id) }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: profile.isBuiltin ? duplicate : edit)
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

/// Edits a local or SSH profile. Fields write straight into `profile.options`, so options
/// this editor doesn't know about are preserved.
struct ProfileEditorSheet: View {
    let item: EditableProfile
    let done: (Profile?) -> Void
    @State private var profile: Profile
    @State private var groupName: String

    init(item: EditableProfile, done: @escaping (Profile?) -> Void) {
        self.item = item
        self.done = done
        _profile = State(initialValue: item.profile)
        let registry = AppServices.shared.profiles
        _groupName = State(initialValue: registry.groups.first { $0.id == item.profile.group }?.name ?? "")
    }

    private func option(_ key: String) -> Binding<String> {
        Binding(get: { profile.options[key]?.stringValue ?? "" },
                set: { profile.options[key] = $0.isEmpty ? .null : .string($0) })
    }

    private func intOption(_ key: String, default value: Int) -> Binding<Int> {
        Binding(get: { profile.options[key]?.intValue ?? value }, set: { profile.options[key] = .int($0) })
    }

    private func boolOption(_ key: String) -> Binding<Bool> {
        Binding(get: { profile.options[key]?.boolValue ?? false }, set: { profile.options[key] = .bool($0) })
    }

    private func listOption(_ key: String) -> Binding<String> {
        Binding(get: { (profile.options[key]?.stringArrayValue ?? []).joined(separator: "\n") },
                set: { profile.options[key] = .array($0.split(separator: "\n").map { .string(String($0)) }) })
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Profile") {
                    TextField("Name", text: $profile.name)
                    TextField("Group", text: $groupName)
                    TextField("Color", text: Binding(get: { profile.color ?? "" }, set: { profile.color = $0.isEmpty ? nil : $0 }))
                    Picker("When the session ends", selection: $profile.behaviorOnSessionEnd) {
                        Text("Auto").tag(SessionEndBehavior.auto)
                        Text("Keep the tab open").tag(SessionEndBehavior.keep)
                        Text("Reconnect").tag(SessionEndBehavior.reconnect)
                        Text("Close the tab").tag(SessionEndBehavior.close)
                    }
                    Toggle("Ignore titles set by programs", isOn: $profile.disableDynamicTitle)
                }
                if profile.type == "local" {
                    Section("Shell") {
                        TextField("Command", text: option("command"))
                        TextField("Arguments (one per line)", text: listOption("args"), axis: .vertical)
                        TextField("Working directory", text: option("cwd"))
                        Toggle("Keep the tab open after the process exits", isOn: boolOption("pauseAfterExit"))
                    }
                } else if profile.type == "ssh" {
                    sshSections
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(item.isNew ? "Create" : "Save") { done(finalProfile()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(profile.type == "ssh" && (profile.options["host"]?.stringValue ?? "").isEmpty)
            }
            .padding()
        }
        .frame(width: 560, height: 620)
    }

    @ViewBuilder
    private var sshSections: some View {
        Section("Connection") {
            TextField("Host", text: option("host"))
            TextField("Port", value: intOption("port", default: 22), format: .number.grouping(.never))
            TextField("Username", text: option("user"))
            Picker("Authentication", selection: option("auth")) {
                Text("Automatic").tag("")
                Text("Password").tag("password")
                Text("Key").tag("publicKey")
                Text("Agent").tag("agent")
                Text("Keyboard-interactive").tag("keyboardInteractive")
            }
            TextField("Private keys (one path per line)", text: listOption("privateKeys"), axis: .vertical)
            Picker("Jump host", selection: option("jumpHost")) {
                Text("None").tag("")
                ForEach(AppServices.shared.profiles.allProfiles(includeHidden: true).filter { $0.type == "ssh" && !$0.isTemplate && $0.id != profile.id }, id: \.id) { p in
                    Text(p.name).tag(p.id)
                }
            }
            TextField("Proxy command", text: option("proxyCommand"))
        }
        Section("Advanced") {
            Toggle("Agent forwarding", isOn: boolOption("agentForward"))
            Toggle("X11 forwarding", isOn: boolOption("x11"))
            Toggle("Reuse connection for new tabs", isOn: Binding(get: { profile.options["reuseSession"]?.boolValue ?? true },
                                                                  set: { profile.options["reuseSession"] = .bool($0) }))
            Toggle("Skip the login banner", isOn: boolOption("skipBanner"))
            TextField("Keep-alive interval (ms)", value: intOption("keepaliveInterval", default: 5000), format: .number.grouping(.never))
            TextField("Terminal type", text: option("term"))
            TextField("Start in directory", text: option("cwd"))
        }
        Section("Port forwarding") {
            PortForwardsEditor(options: $profile.options)
        }
    }

    private func finalProfile() -> Profile {
        var p = profile
        let registry = AppServices.shared.profiles
        let name = groupName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            p.group = nil
        } else if let g = registry.groups.first(where: { $0.name == name }) {
            p.group = g.id
        } else {
            let g = ProfileGroup(name: name)
            registry.save(g)
            p.group = g.id
        }
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

struct PortForwardsEditor: View {
    @Binding var options: ConfigValue

    var body: some View {
        let forwards = (options["forwardedPorts"]?.arrayValue ?? []).compactMap(ForwardedPort.init)
        ForEach(Array(forwards.enumerated()), id: \.offset) { index, f in
            HStack {
                Text(f.type.rawValue).frame(width: 70, alignment: .leading)
                Text(f.type == .dynamic ? "\(f.host):\(f.port)" : "\(f.host):\(f.port) → \(f.targetAddress):\(f.targetPort)")
                Spacer()
                Button(role: .destructive) {
                    var list = forwards
                    list.remove(at: index)
                    options["forwardedPorts"] = .array(list.map(\.configValue))
                } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
            }
        }
        Menu("Add forward") {
            ForEach(PortForwardType.allCases, id: \.self) { type in
                Button(type.rawValue) {
                    var list = forwards
                    list.append(ForwardedPort(type: type, host: "127.0.0.1", port: 8080, targetAddress: "localhost", targetPort: 80))
                    options["forwardedPorts"] = .array(list.map(\.configValue))
                }
            }
        }
        Text("Edit the addresses in Config file for now; forwards apply when the session starts.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
#endif
