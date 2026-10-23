#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbySSH
import TabbyAccount
import TabbySyncProtocol

/// Settings › Account & sync (the design's A4 signed out, A5 signed in). The server is fixed;
/// there is no server setting.
struct AccountSettingsView: View {
    @Environment(\.chrome) private var chrome
    @State private var message: String?

    var body: some View {
        let account = AppServices.shared.account
        let _ = AppServices.shared.configRevision
        SettingsPage(L("Account & sync")) {
            if let session = account.session {
                signedIn(account, session)
            } else {
                signedOut
            }
        }
        .task { if account.isSignedIn { await account.refreshDevices() } }
    }

    private var signedOut: some View {
        SignedOutAccountCard(createAccount: { AccountSheets.present(.register, in: NSApp.keyWindow) },
                             signIn: { AccountSheets.present(.signIn, in: NSApp.keyWindow) })
    }

    @ViewBuilder
    private func signedIn(_ account: AccountService, _ session: AccountSession) -> some View {
        SettingsGroup {
            HStack(spacing: 12) {
                AccountAvatar(email: session.email, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.email).font(ChromeFont.bodyEmphasised)
                    Text(L("Personal account")).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                }
                Spacer()
                Button(L("Sign out…")) { AccountSheets.presentSignOut(in: NSApp.keyWindow) }.buttonStyle(ChromeButtonStyle())
            }
            .padding(14)
            HStack(spacing: 10) {
                statusIcon(account.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(account.status)).font(ChromeFont.bodyEmphasised)
                    Text(verbatim: "\(accountStatusLine(account)) · " + [Plural.count(account.counts.profiles, one: "1 profile", other: "{n} profiles"), Plural.count(account.counts.passwords, one: "1 password", other: "{n} passwords"), Plural.count(account.counts.keys, one: "1 key", other: "{n} keys")].joined(separator: ", "))
                        .font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).lineLimit(2)
                }
                Spacer()
                Toggle(L("Auto"), isOn: ConfigBinding.bool("account.auto")).toggleStyle(.checkbox)
                Button { Task { await account.syncNow() } } label: { Label(L("Sync now"), systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(account.status == .syncing)
            }
            .padding(14)
        }
        SettingsGroup(L("What to sync")) {
            SettingsRow(L("Profiles & connections"), isOn: ConfigBinding.bool("account.parts.profiles"))
            SettingsRow(L("Passwords & private keys"), subtitle: L("SSH passwords and key passphrases from the Keychain, and the key files you approve"),
                        isOn: ConfigBinding.bool("account.parts.secrets"))
            SettingsRow(L("Known hosts"), isOn: ConfigBinding.bool("account.parts.knownHosts"))
            SettingsRow(L("Settings, hotkeys & colour schemes"), isOn: ConfigBinding.bool("account.parts.settings"))
        }
        keyFiles(account)
        SettingsGroup(L("Devices"), footer: L("Removing a Mac signs it out; it stops receiving updates.")) {
            if account.devices.isEmpty {
                SettingsRow(L("Loading devices…")) { EmptyView() }
            }
            ForEach(account.devices, id: \.id) { d in
                SettingsRow(d.name, subtitle: L("{os} · last seen {time}", ["os": d.os, "time": Self.relative(d.lastSeenAt)])) {
                    if d.isCurrent {
                        Text(L("This Mac")).font(ChromeFont.caption).padding(.horizontal, 8).frame(height: 20)
                            .foregroundStyle(chrome.accent.color).background(Capsule().fill(chrome.accentFill.color))
                    } else {
                        Button(L("Remove")) {
                            Task {
                                do { try await account.removeDevice(d.id) } catch { message = error.localizedDescription }
                            }
                        }
                        .buttonStyle(ChromeButtonStyle(kind: .plain))
                    }
                }
            }
        }
        SettingsGroup(L("Security"), footer: message) {
            SettingsRow(L("End-to-end encrypted"), subtitle: L("The server stores ciphertext only; your password never leaves this Mac.")) {
                Image(systemName: "lock.shield").foregroundStyle(chrome.success.color)
            }
            SettingsRow(L("Recovery key"), subtitle: session.recoveryKey == nil ? L("Not on this Mac yet (it arrives with the next sync)") : L("Unlocks the account if you forget the password")) {
                HStack(spacing: 6) {
                    Button(L("View…")) { askPassword(title: L("Show the recovery key")) { pw in
                        if let key = try await account.revealRecoveryKey(password: pw) {
                            message = nil
                            AccountSheets.present(.recoveryKey(key, .viewed), in: NSApp.keyWindow)
                        } else {
                            message = L("The recovery key is not on this Mac yet.")
                        }
                    } }
                    .disabled(session.recoveryKey == nil)
                    Button(L("Regenerate…")) { askPassword(title: L("Make a new recovery key"), message: L("The current key stops working. Your TabbyMac account password:")) { pw in
                        let key = try await account.regenerateRecoveryKey(password: pw)
                        message = nil
                        AccountSheets.present(.recoveryKey(key.displayString, .regenerated), in: NSApp.keyWindow)
                    } }
                }
                .buttonStyle(ChromeButtonStyle())
            }
            SettingsRow(L("Password")) {
                Button(L("Change…")) { changePassword(account) }.buttonStyle(ChromeButtonStyle())
            }
            SettingsRow(L("Delete account"), subtitle: L("Removes the account and its encrypted data from the server. This Mac keeps its copy.")) {
                Button(L("Delete account…")) { askPassword(title: L("Delete your account?"), message: L("Every Mac is signed out and the synced data is deleted from the server."), confirm: L("Delete")) { pw in
                    try await account.deleteAccount(password: pw)
                } }
                .buttonStyle(ChromeButtonStyle(kind: .destructive))
            }
        }
    }

    @ViewBuilder
    private func keyFiles(_ account: AccountService) -> some View {
        let config = AppServices.shared.config
        let approved = config.value("account.approvedKeyFiles")?.stringArrayValue ?? []
        let declined = config.value("account.declinedKeyFiles")?.stringArrayValue ?? []
        if !account.pendingKeyFiles.isEmpty || !approved.isEmpty || !declined.isEmpty {
            SettingsGroup(L("Private key files")) {
                if !account.pendingKeyFiles.isEmpty {
                    SettingsRow(Plural.count(account.pendingKeyFiles.count, one: "1 key file is waiting for your answer",
                                             other: "{n} key files are waiting for your answer")) {
                        Button(L("Review…")) { AccountSheets.presentKeyFiles(account.pendingKeyFiles, in: NSApp.keyWindow) }
                            .buttonStyle(ChromeButtonStyle(kind: .primary))
                    }
                }
                SettingsRow(L("{approvedCount} approved, {declinedCount} kept on this Mac only", ["approvedCount": approved.count, "declinedCount": declined.count])) {
                    Button(L("Ask again")) {
                        config.set("account.approvedKeyFiles", nil)
                        config.set("account.declinedKeyFiles", nil)
                        Task { await account.syncNow() }
                    }
                    .buttonStyle(ChromeButtonStyle())
                }
            }
        }
    }

    private func statusIcon(_ status: AccountService.Status) -> some View {
        Group {
            switch status {
            case .syncing: ProgressView().controlSize(.small)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(chrome.warning.color)
            default: Image(systemName: "checkmark.circle.fill").foregroundStyle(chrome.success.color)
            }
        }
        .frame(width: 22)
    }

    private func statusTitle(_ status: AccountService.Status) -> String {
        switch status {
        case .syncing: return L("Syncing")
        case .failed: return L("Not synced")
        case .signedOut: return L("Signed out")
        case .upToDate: return L("Up to date")
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func askPassword(title: String, message text: String = L("Your TabbyMac account password."), confirm: String = L("Continue"),
                             _ action: @escaping (String) async throws -> Void) {
        Prompts.text(in: NSApp.keyWindow, title: title, message: text, secure: true, confirm: confirm) { value, _ in
            guard let value, !value.isEmpty else { return }
            Task {
                do { try await action(value) } catch { message = error.localizedDescription }
            }
        }
    }

    private func changePassword(_ account: AccountService) {
        askPassword(title: L("Current password")) { old in
            Prompts.text(in: NSApp.keyWindow, title: L("New password"), message: L("At least 8 characters."), secure: true, confirm: L("Continue")) { new, _ in
                guard let new else { return }
                Prompts.text(in: NSApp.keyWindow, title: L("Type the new password again"), secure: true, confirm: L("Change")) { again, _ in
                    guard let again else { return }
                    if let problem = NewPasswordCheck.problem(new: new, again: again) {
                        message = problem
                        return
                    }
                    Task {
                        do {
                            try await account.changePassword(old: old, new: new)
                            message = L("Password changed. Your other Macs stay signed in.")
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

/// Settings › Vault: the SSH passwords and key passphrases TabbyMac keeps in the Keychain
/// (what "Passwords & private keys" syncs), and the key files that arrived through sync.
struct VaultSettingsView: View {
    @State private var revealed: [SavedSecret: String] = [:]
    @State private var refresh = 0
    @Environment(\.chrome) private var chrome

    var body: some View {
        let services = AppServices.shared
        let _ = refresh
        let secrets = ((try? services.passwords.savedSecrets()) ?? []).sorted { Self.title($0) < Self.title($1) }
        let keys = services.keyFiles.records()
        SettingsPage(L("Vault")) {
            SettingsGroup(L("Saved in the Keychain"), footer: L("TabbyMac saves these when you tick “Remember” at a password or passphrase prompt. Showing one may ask for your Mac password.")) {
                if secrets.isEmpty { SettingsRow(L("No saved passwords")) { EmptyView() } }
                ForEach(secrets, id: \.self) { secret in
                    SettingsRow(Self.title(secret), subtitle: revealed[secret] ?? Self.subtitle(secret)) {
                        HStack(spacing: 6) {
                            Button(revealed[secret] == nil ? L("Show") : L("Hide")) { toggle(secret) }
                            Button(L("Remove")) { remove(secret) }.foregroundStyle(chrome.danger.color)
                        }
                        .buttonStyle(ChromeButtonStyle(kind: .plain))
                    }
                }
            }
            SettingsGroup(L("Private keys from your account"), footer: L("Used when the original key file is not on this Mac.")) {
                if keys.isEmpty { SettingsRow(L("None")) { EmptyView() } }
                ForEach(keys, id: \.id) { k in
                    SettingsRow(k.originalPath, subtitle: k.isDefaultIdentity ? L("ssh default identity") : nil) {
                        Button(L("Remove")) {
                            services.keyFiles.remove(id: k.id)
                            refresh += 1
                        }
                        .buttonStyle(ChromeButtonStyle(kind: .plain))
                    }
                }
            }
        }
    }

    static func title(_ s: SavedSecret) -> String {
        switch s {
        case let .password(host, port, user): return port > 0 && port != 22 ? "\(user)@\(host):\(port)" : "\(user)@\(host)"
        case let .passphrase(keyID): return L("Key passphrase {id}…", ["id": keyID.prefix(12)])
        }
    }

    static func subtitle(_ s: SavedSecret) -> String {
        switch s {
        case .password: return "SSH password · ••••••••"
        case .passphrase: return L("Private key passphrase · ••••••••")
        }
    }

    private func toggle(_ secret: SavedSecret) {
        if revealed[secret] != nil {
            revealed[secret] = nil
            return
        }
        let store = AppServices.shared.passwords
        switch secret {
        case let .password(host, port, user): revealed[secret] = store.password(host: host, port: port, user: user)
        case let .passphrase(keyID): revealed[secret] = store.passphrase(keyID: keyID)
        }
    }

    private func remove(_ secret: SavedSecret) {
        Prompts.confirm(in: NSApp.keyWindow, title: L("Remove {name}?", ["name": Self.title(secret)]),
                        message: L("It is deleted from the Keychain, and from your other Macs at the next sync."),
                        confirm: L("Remove"), destructive: true) { ok in
            guard ok else { return }
            let store = AppServices.shared.passwords
            switch secret {
            case let .password(host, port, user): store.deletePassword(host: host, port: port, user: user)
            case let .passphrase(keyID): store.deletePassphrase(keyID: keyID)
            }
            revealed[secret] = nil
            refresh += 1
        }
    }
}
/// Settings › Account & sync while signed out.
struct SignedOutAccountCard: View {
    let createAccount: () -> Void
    let signIn: () -> Void
    @Environment(\.chrome) private var chrome

    /// One row when it fits; in a narrow window the buttons go under the text.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                icon
                text.frame(minWidth: 220, alignment: .leading)
                Spacer(minLength: 0)
                buttons
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) { icon; text }
                HStack(spacing: 8) { Spacer(minLength: 0); buttons }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
    }

    private var icon: some View {
        Image(systemName: "arrow.triangle.2.circlepath.icloud").font(.system(size: 26)).foregroundStyle(chrome.accent.color)
            .frame(width: 52, height: 52).background(Circle().fill(chrome.accentFill.color))
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Use TabbyMac on every Mac")).font(ChromeFont.headline)
            Text(L("Sign in to sync profiles, passwords, private keys and settings. Everything is encrypted on this Mac before it leaves it."))
                .font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        Button(L("Create account"), action: createAccount).buttonStyle(ChromeButtonStyle(large: true)).fixedSize()
        Button(L("Sign in…"), action: signIn).buttonStyle(ChromeButtonStyle(kind: .primary, large: true)).fixedSize()
    }
}
#endif
