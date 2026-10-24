#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore

/// Tabby's `EditProfileGroupModalComponent`: name, parent group, icon, colour, and the
/// per-type defaults of the group's profiles.
struct ProfileGroupEditorSheet: View {
    let isNew: Bool
    let done: (ProfileGroup?) -> Void
    /// Opens the profile editor on this group's defaults for a type.
    let editDefaults: (ProfileGroup, String) -> Void
    @State private var group: ProfileGroup
    @Environment(\.chrome) private var chrome

    init(group: ProfileGroup, isNew: Bool, done: @escaping (ProfileGroup?) -> Void,
         editDefaults: @escaping (ProfileGroup, String) -> Void) {
        self.isNew = isNew
        self.done = done
        self.editDefaults = editDefaults
        _group = State(initialValue: group)
    }

    var body: some View {
        let registry = AppServices.shared.profiles
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(group.name.isEmpty ? L("New profile group") : group.name).font(ChromeFont.headline)
                    SettingsGroup {
                        SettingsRow(L("Name")) { RowField(placeholder: L("Name"), text: $group.name, width: 260) }
                        SettingsRow(L("Parent group")) {
                            RowPicker(selection: Binding(get: { group.parentGroupId ?? "" }, set: { group.parentGroupId = $0.isEmpty ? nil : $0 })) {
                                Text(L("Ungrouped")).tag("")
                                ForEach(registry.validParents(for: group.id), id: \.id) { g in
                                    Text(verbatim: registry.groupPath(g.id)).tag(g.id)
                                }
                            }
                        }
                        SettingsRow(L("Icon")) { ProfileIconPicker(icon: $group.icon, placeholder: "far fa-folder") } // l10n-ignore: Font Awesome class
                        SettingsRow(L("Color")) { ProfileColorPicker(color: $group.color) }
                    }
                    SettingsGroup(L("Default profile group settings"), footer: L("These apply to all profiles of a given type in this group")) {
                        ForEach(ProfileTypes.creatable, id: \.self) { type in
                            SettingsRow(ProfileTypes.title(type)) {
                                HStack(spacing: 6) {
                                    Button(L("Edit…")) { editDefaults(group, type) }.buttonStyle(ChromeButtonStyle())
                                    IconButton(symbol: "arrow.uturn.backward", help: L("Restore settings to defaults"), size: 22) {
                                        group.defaults[type] = nil
                                    }
                                    .disabled(group.defaults[type]?.objectValue?.isEmpty ?? true)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            HStack {
                Spacer()
                Button(L("Cancel")) { done(nil) }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? L("Create") : L("Save")) { done(group) }
                    .buttonStyle(ChromeButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(group.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 560)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
    }
}

/// Deleting a group the way Tabby asks (`deleteProfileGroup`).
@MainActor
enum ProfileGroupActions {
    /// Shows `message` with `buttons` and answers the index of the one clicked.
    typealias Ask = (_ message: String, _ buttons: [String], _ answer: @escaping (Int) -> Void) -> Void

    static let defaultAsk: Ask = { message, buttons, answer in
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        for title in buttons { alert.addButton(withTitle: title) }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { answer($0.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        } else {
            answer(alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
    }
    /// Tests answer the questions.
    static var ask: Ask = defaultAsk

    /// "Delete "{name}"?" (Delete / Keep); when the group has profiles, "Delete the group's
    /// profiles?" (Move to "Ungrouped" / Delete).
    static func delete(_ group: ProfileGroup, registry: ProfileRegistry, done: @escaping () -> Void = {}) {
        ask(L("Delete \"{name}\"?", ["name": group.name]), [L("Delete"), L("Keep")]) { first in
            guard first == 0 else { return done() }
            guard registry.userProfiles.contains(where: { $0.group == group.id }) else {
                registry.delete(groupId: group.id)
                return done()
            }
            ask(L("Delete the group's profiles?"), [L("Move to \"Ungrouped\""), L("Delete")]) { second in
                registry.delete(groupId: group.id, deleteProfiles: second == 1)
                done()
            }
        }
    }

    /// "Restore settings to defaults ?" (Delete / Keep) before clearing a type's defaults.
    static func resetTypeDefaults(_ type: String, registry: ProfileRegistry) {
        ask(L("Restore settings to defaults ?"), [L("Delete"), L("Keep")]) { answer in
            if answer == 0 { registry.setTypeDefaults(type, nil) }
        }
    }
}
#endif
