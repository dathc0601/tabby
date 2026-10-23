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
        SettingsPage("Account & sync") {
            if let session = account.session {
                signedIn(account, session)
            } else {
                signedOut
            }
        }
        .task { if account.isSignedIn { await account.refreshDevices() } }
    }

    private var signedOut: some View {
        HStack(spacing: 18) {
            Image(systemName: "arrow.triangle.2.circlepath.icloud").font(.system(size: 26)).foregroundStyle(chrome.accent.color)
                .frame(width: 52, height: 52).background(Circle().fill(chrome.accentFill.color))
            VStack(alignment: .leading, spacing: 4) {
                Text("Use TabbyMac on every Mac").font(ChromeFont.headline)
                Text("Sign in to sync profiles, passwords, private keys and settings. Everything is encrypted on this Mac before it leaves it.")
                    .font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Create account") { AccountSheets.present(.register, in: NSApp.keyWindow) }.buttonStyle(ChromeButtonStyle(large: true))
            Button("Sign in…") { AccountSheets.present(.signIn, in: NSApp.keyWindow) }.buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(chrome.border.color, lineWidth: 0.5))
    }

    @ViewBuilder
    private func signedIn(_ account: AccountService, _ session: AccountSession) -> some View {
        SettingsGroup {
            HStack(spacing: 12) {
                AccountAvatar(email: session.email, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.email).font(ChromeFont.bodyEmphasised)
                    Text("Personal account").font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                }
                Spacer()
                Button("Sign out…") { AccountSheets.presentSignOut(in: NSApp.keyWindow) }.buttonStyle(ChromeButtonStyle())
            }
            .padding(14)
            HStack(spacing: 10) {
                statusIcon(account.status)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle(account.status)).font(ChromeFont.bodyEmphasised)
                    Text(verbatim: "\(accountStatusLine(account)) · " + [Plural.count(account.counts.profiles, "profile"), Plural.count(account.counts.passwords, "password"), Plural.count(account.counts.keys, "key")].joined(separator: ", "))
                        .font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color).lineLimit(2)
                }
                Spacer()
                Toggle("Auto", isOn: ConfigBinding.bool("account.auto")).toggleStyle(.checkbox)
                Button { Task { await account.syncNow() } } label: { Label("Sync now", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(ChromeButtonStyle())
                    .disabled(account.status == .syncing)
            }
            .padding(14)
        }
        SettingsGroup("What to sync") {
            SettingsRow("Profiles & connections", isOn: ConfigBinding.bool("account.parts.profiles"))
            SettingsRow("Passwords & private keys", subtitle: "SSH passwords and key passphrases from the Keychain, and the key files you approve",
                        isOn: ConfigBinding.bool("account.parts.secrets"))
            SettingsRow("Known hosts", isOn: ConfigBinding.bool("account.parts.knownHosts"))
            SettingsRow("Settings, hotkeys & colour schemes", isOn: ConfigBinding.bool("account.parts.settings"))
        }
        keyFiles(account)
        SettingsGroup("Devices", footer: "Removing a Mac signs it out; it stops receiving updates.") {
            if account.devices.isEmpty {
                SettingsRow("Loading devices…") { EmptyView() }
            }
            ForEach(account.devices, id: \.id) { d in
                SettingsRow(d.name, subtitle: "\(d.os) · last seen \(Self.relative(d.lastSeenAt))") {
                    if d.isCurrent {
                        Text("This Mac").font(ChromeFont.caption).padding(.horizontal, 8).frame(height: 20)
                            .foregroundStyle(chrome.accent.color).background(Capsule().fill(chrome.accentFill.color))
                    } else {
                        Button("Remove") {
                            Task {
                                do { try await account.removeDevice(d.id) } catch { message = error.localizedDescription }
                            }
                        }
                        .buttonStyle(ChromeButtonStyle(kind: .plain))
                    }
                }
            }
        }
        SettingsGroup("Security", footer: message) {
            SettingsRow("End-to-end encrypted", subtitle: "The server stores ciphertext only; your password never leaves this Mac.") {
                Image(systemName: "lock.shield").foregroundStyle(chrome.success.color)
            }
            SettingsRow("Recovery key", subtitle: session.recoveryKey == nil ? "Not on this Mac yet (it arrives with the next sync)" : "Unlocks the account if you forget the password") {
                HStack(spacing: 6) {
                    Button("View…") { askPassword(title: "Show the recovery key") { pw in
                        let key = try await account.revealRecoveryKey(password: pw)
                        message = key.map { "Recovery key: \($0)" } ?? "The recovery key is not on this Mac yet."
                    } }
                    .disabled(session.recoveryKey == nil)
                    Button("Regenerate…") { askPassword(title: "Make a new recovery key", message: "The current key stops working.") { pw in
                        let key = try await account.regenerateRecoveryKey(password: pw)
                        AccountSheets.present(.recoveryKey(key.displayString), in: NSApp.keyWindow)
                    } }
                }
                .buttonStyle(ChromeButtonStyle())
            }
            SettingsRow("Password") {
                Button("Change…") { changePassword(account) }.buttonStyle(ChromeButtonStyle())
            }
            SettingsRow("Delete account", subtitle: "Removes the account and its encrypted data from the server. This Mac keeps its copy.") {
                Button("Delete account…") { askPassword(title: "Delete your account?", message: "Every Mac is signed out and the synced data is deleted from the server.", confirm: "Delete") { pw in
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
            SettingsGroup("Private key files") {
                if !account.pendingKeyFiles.isEmpty {
                    SettingsRow(account.pendingKeyFiles.count == 1 ? "1 key file is waiting for your answer"
                                : "\(account.pendingKeyFiles.count) key files are waiting for your answer") {
                        Button("Review…") { AccountSheets.presentKeyFiles(account.pendingKeyFiles, in: NSApp.keyWindow) }
                            .buttonStyle(ChromeButtonStyle(kind: .primary))
                    }
                }
                SettingsRow("\(approved.count) approved, \(declined.count) kept on this Mac only") {
                    Button("Ask again") {
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
        case .syncing: return "Syncing"
        case .failed: return "Not synced"
        case .signedOut: return "Signed out"
        case .upToDate: return "Up to date"
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func askPassword(title: String, message text: String = "", confirm: String = "Continue",
                             _ action: @escaping (String) async throws -> Void) {
        Prompts.text(in: NSApp.keyWindow, title: title, message: text, secure: true, confirm: confirm) { value, _ in
            guard let value, !value.isEmpty else { return }
            Task {
                do { try await action(value) } catch { message = error.localizedDescription }
            }
        }
    }

    private func changePassword(_ account: AccountService) {
        askPassword(title: "Current password") { old in
            Prompts.text(in: NSApp.keyWindow, title: "New password", message: "At least 8 characters.", secure: true, confirm: "Change") { new, _ in
                guard let new, PasswordStrength.score(new) >= 2 else {
                    message = "The new password is too short."
                    return
                }
                Task {
                    do {
                        try await account.changePassword(old: old, new: new)
                        message = "Password changed. Your other Macs stay signed in."
                    } catch {
                        message = error.localizedDescription
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
        SettingsPage("Vault") {
            SettingsGroup("Saved in the Keychain", footer: "TabbyMac saves these when you tick “Remember” at a password or passphrase prompt. Showing one may ask for your Mac password.") {
                if secrets.isEmpty { SettingsRow("No saved passwords") { EmptyView() } }
                ForEach(secrets, id: \.self) { secret in
                    SettingsRow(Self.title(secret), subtitle: revealed[secret] ?? Self.subtitle(secret)) {
                        HStack(spacing: 6) {
                            Button(revealed[secret] == nil ? "Show" : "Hide") { toggle(secret) }
                            Button("Remove") { remove(secret) }.foregroundStyle(chrome.danger.color)
                        }
                        .buttonStyle(ChromeButtonStyle(kind: .plain))
                    }
                }
            }
            SettingsGroup("Private keys from your account", footer: "Used when the original key file is not on this Mac.") {
                if keys.isEmpty { SettingsRow("None") { EmptyView() } }
                ForEach(keys, id: \.id) { k in
                    SettingsRow(k.originalPath, subtitle: k.isDefaultIdentity ? "ssh default identity" : nil) {
                        Button("Remove") {
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
        case let .passphrase(keyID): return "Key passphrase \(keyID.prefix(12))…"
        }
    }

    static func subtitle(_ s: SavedSecret) -> String {
        switch s {
        case .password: return "SSH password · ••••••••"
        case .passphrase: return "Private key passphrase · ••••••••"
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
        Prompts.confirm(in: NSApp.keyWindow, title: "Remove \(Self.title(secret))?",
                        message: "It is deleted from the Keychain, and from your other Macs at the next sync.",
                        confirm: "Remove", destructive: true) { ok in
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
#endif
