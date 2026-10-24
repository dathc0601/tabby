#if canImport(AppKit)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TabbyCore
import TabbyAccount
import TabbySyncProtocol

// MARK: - Shared pieces

/// Initials in a circle, with a status badge when signed in (the design's toolbar avatar).
struct AccountAvatar: View {
    let email: String
    var size: CGFloat = 22
    var status: AccountService.Status?
    @Environment(\.chrome) private var chrome

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(Self.initials(email)).font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(chrome.onAccent.color)
                .frame(width: size, height: size)
                .background(Circle().fill(chrome.accent.color))
            if let status {
                badge(status)
                    .frame(width: size * 0.5, height: size * 0.5)
                    .background(Circle().fill(chrome.surfaceChrome.color).padding(-1.5))
                    .offset(x: 2, y: 2)
            }
        }
    }

    @ViewBuilder
    private func badge(_ status: AccountService.Status) -> some View {
        switch status {
        case .syncing:
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: size * 0.32, weight: .bold)).foregroundStyle(chrome.accent.color)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: size * 0.42)).foregroundStyle(chrome.warning.color)
        default:
            Image(systemName: "checkmark.circle.fill").font(.system(size: size * 0.42)).foregroundStyle(chrome.success.color)
        }
    }

    static func initials(_ email: String) -> String {
        let name = email.split(separator: "@").first.map(String.init) ?? email
        let parts = name.split(whereSeparator: { ".-_+".contains($0) })
        let letters = parts.prefix(2).compactMap(\.first)
        return String(letters.isEmpty ? Array(name.prefix(1)) : letters).uppercased()
    }
}

/// "Synced 2 min ago" / "Syncing…" / the error.
@MainActor
func accountStatusLine(_ account: AccountService) -> String {
    switch account.status {
    case .signedOut: return L("Signed out")
    case .syncing: return L("Syncing…")
    case .failed(let message): return message
    case .upToDate:
        guard let date = account.lastSyncAt else { return L("Up to date") }
        if Date().timeIntervalSince(date) < 30 { return L("Synced just now") }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Synced " + f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Toolbar

/// The account button at the end of the toolbar: a person icon when signed out (opens
/// sign-in), the avatar with a sync badge and a popover when signed in.
struct AccountToolbarButton: View {
    let openSettings: () -> Void
    @State private var showPopover = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        let account = AppServices.shared.account
        if let session = account.session {
            Button { showPopover.toggle() } label: {
                AccountAvatar(email: session.email, status: account.status)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(session.email) · \(accountStatusLine(account))")
            .popover(isPresented: $showPopover, arrowEdge: .bottom) {
                AccountPopover(close: { showPopover = false }, openSettings: openSettings).chromeEnvironment()
            }
        } else {
            IconButton(symbol: "person.crop.circle", help: L("Sign in to sync profiles and keys")) {
                AccountSheets.present(.signIn, in: NSApp.keyWindow)
            }
        }
    }
}

/// The design's account popover: who, sync state, devices, Sync now, settings, sign out.
struct AccountPopover: View {
    let close: () -> Void
    let openSettings: () -> Void
    @Environment(\.chrome) private var chrome

    var body: some View {
        let account = AppServices.shared.account
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                AccountAvatar(email: account.session?.email ?? "", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.session?.email ?? "").font(ChromeFont.bodyEmphasised)
                    Text(L("Personal account")).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                }
            }
            .padding(14)
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if account.status == .syncing { ProgressView().controlSize(.small) }
                    Text(accountStatusLine(account)).font(ChromeFont.callout).lineLimit(2)
                }
                Text(verbatim: [Plural.count(account.counts.profiles, one: "1 profile", other: "{n} profiles"), Plural.count(account.counts.passwords, one: "1 password", other: "{n} passwords"), Plural.count(account.counts.keys, one: "1 key", other: "{n} keys")].joined(separator: " · "))
                    .font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                if !account.devices.isEmpty {
                    Label(Plural.count(account.devices.count, one: "1 Mac", other: "{n} Macs"), systemImage: "laptopcomputer").font(ChromeFont.caption)
                        .foregroundStyle(chrome.textMuted.color)
                }
            }
            .padding(14)
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            VStack(spacing: 2) {
                row("arrow.triangle.2.circlepath", L("Sync now"), shortcut: StartPageView.shortcut("sync-now")) {
                    Task { await account.syncNow() }
                }
                row("person.crop.circle", L("Account & sync settings…")) {
                    close()
                    openSettings()
                }
                row("rectangle.portrait.and.arrow.right", L("Sign out…")) {
                    close()
                    AccountSheets.presentSignOut(in: NSApp.keyWindow)
                }
            }
            .padding(6)
        }
        .frame(width: 290)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .task { await account.refreshDevices() }
    }

    private func row(_ symbol: String, _ title: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        PopoverRow(symbol: symbol, title: title, shortcut: shortcut, action: action)
    }
}

private struct PopoverRow: View {
    let symbol: String
    let title: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(chrome.textMuted.color)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).font(ChromeFont.caption).foregroundStyle(chrome.textFaint.color) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? chrome.fill.color : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Sign in, create account, recovery key, restore

enum RecoveryKeyPurpose: Equatable {
    case signUp, regenerated, viewed
}

/// What the recovery key card says: the second step of signing up, a key just regenerated,
/// or the current key shown again (Settings › Account & sync › View…).
struct RecoveryKeyTexts: Equatable {
    var step: String?
    var title: String
    var message: String
    var footer: String?
    var confirm: String
    /// The "I've stored the recovery key somewhere safe" box must be ticked first.
    var needsSavedConfirmation: Bool

    init(purpose: RecoveryKeyPurpose, profiles: Int) {
        switch purpose {
        case .signUp:
            step = L("Step 2 of 2")
            title = L("Save your recovery key")
            message = L("If you forget your password, this key is the only way to decrypt your synced profiles and private keys. TabbyMac can't reset it for you.")
            footer = L("{profiles} on this Mac will upload next", ["profiles": Plural.count(profiles, one: "1 profile", other: "{n} profiles")])
            confirm = L("Start syncing")
            needsSavedConfirmation = true
        case .regenerated:
            step = nil
            title = L("Your new recovery key")
            message = L("The old key no longer works. Keep this one somewhere safe: with your email it unlocks your synced data if you forget your password.")
            footer = nil
            confirm = L("Done")
            needsSavedConfirmation = true
        case .viewed:
            step = nil
            title = L("Your recovery key")
            message = L("With your email it unlocks your synced data if you forget your password.")
            footer = nil
            confirm = L("Done")
            needsSavedConfirmation = false
        }
    }
}

/// Change password…: the new password is typed twice, as at sign-up.
enum NewPasswordCheck {
    static func problem(new: String, again: String) -> String? {
        if PasswordStrength.score(new) < 2 { return L("The new password is too short.") }
        if new != again { return L("The passwords don't match; nothing was changed.") }
        return nil
    }
}

enum AccountSheetMode: Equatable {
    case signIn
    case register
    case forgotPassword
    case recoveryKey(String, RecoveryKeyPurpose = .signUp)
    case restored
}

@MainActor
enum AccountSheets {
    static func present(_ mode: AccountSheetMode, in window: NSWindow?) {
        ChromeSheet.present(in: window) { dismiss in
            AccountSheet(mode: mode, dismiss: dismiss)
        }
    }

    static func presentSignOut(in window: NSWindow?) {
        ChromeSheet.present(in: window) { dismiss in
            SignOutSheet(dismiss: dismiss)
        }
    }

    static func presentKeyFiles(_ files: [KeyFileCandidate], in window: NSWindow?) {
        ChromeSheet.present(in: window) { dismiss in
            KeyFilesSheet(files: files, dismiss: dismiss)
        }
    }
}

/// The design's A1–A3 and A8: one sheet that moves between sign-in, creating an account, the
/// recovery key and "Welcome back".
struct AccountSheet: View {
    @State var mode: AccountSheetMode
    let dismiss: () -> Void
    @State private var email = ""
    @State private var password = ""
    @State private var confirm = ""
    @State private var recoveryKey = ""
    @State private var keepSignedIn = true
    @State private var showPassword = false
    @State private var savedKey = false
    @State private var working = false
    @State private var error: String?
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch mode {
            case .signIn: signIn
            case .register: register
            case .forgotPassword: forgot
            case let .recoveryKey(key, purpose): recovery(key, purpose: purpose)
            case .restored: restored
            }
        }
        .padding(24)
        .frame(width: 440)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .disabled(working)
    }

    private var account: AccountService { AppServices.shared.account }

    private func header(_ symbol: String, _ title: String, _ message: String, step: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let step { Text(step.uppercased()).font(ChromeFont.groupHeader).foregroundStyle(chrome.accent.color) }
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(chrome.accent.color)
                    .frame(width: 40, height: 40).background(Circle().fill(chrome.accentFill.color))
                Text(title).font(ChromeFont.title)
            }
            Text(message).font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ symbol: String, _ placeholder: String, _ text: Binding<String>, secure: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(chrome.textMuted.color).frame(width: 16)
            Group {
                if secure && !showPassword { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain)
            if secure {
                Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye") }
                    .buttonStyle(.plain).foregroundStyle(chrome.textMuted.color).help(showPassword ? L("Hide") : L("Show"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 7).fill(chrome.surface.color))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(chrome.border.color, lineWidth: 0.5))
    }

    @ViewBuilder
    private var errorLine: some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(ChromeFont.callout).foregroundStyle(chrome.danger.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = false
        }
    }

    private var emailIsPlausible: Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && e.contains(".") && e.count >= 5
    }

    // A1
    private var signIn: some View {
        Group {
            header("arrow.triangle.2.circlepath.icloud", L("Sign in to TabbyMac"),
                   L("Your profiles, keys and settings follow you to every Mac. They are encrypted here before upload."))
            field("envelope", L("Email"), $email)
            field("lock", L("Password"), $password, secure: true)
            HStack {
                Toggle(L("Keep me signed in"), isOn: $keepSignedIn).toggleStyle(.checkbox)
                Spacer()
                Button(L("Forgot password?")) { mode = .forgotPassword; error = nil }.buttonStyle(.link)
            }
            errorLine
            HStack {
                Button(L("New to TabbyMac? Create account")) { mode = .register; error = nil }.buttonStyle(.link)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Not now"), action: dismiss).buttonStyle(ChromeButtonStyle(large: true)).keyboardShortcut(.cancelAction)
                Button(L("Sign in")) {
                    run {
                        try await account.signIn(email: email, password: password, keepSignedIn: keepSignedIn)
                        mode = .restored
                    }
                }
                .buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!emailIsPlausible || password.isEmpty)
            }
        }
    }

    // A2
    private var register: some View {
        Group {
            header("person.crop.circle.badge.plus", L("Create your account"),
                   L("Your password also encrypts your synced data. TabbyMac never receives it, so it can't reset it for you."),
                   step: L("Step 1 of 2"))
            field("envelope", L("Email"), $email)
            field("lock", L("Password"), $password, secure: true)
            PasswordStrength(password: password)
            field("lock.rotation", L("Confirm password"), $confirm, secure: true)
            if !confirm.isEmpty && confirm != password {
                Text(L("The passwords don't match.")).font(ChromeFont.caption).foregroundStyle(chrome.danger.color)
            }
            Toggle(L("Keep me signed in"), isOn: $keepSignedIn).toggleStyle(.checkbox)
            errorLine
            HStack {
                Button(L("Have an account? Sign in")) { mode = .signIn; error = nil }.buttonStyle(.link)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Cancel"), action: dismiss).buttonStyle(ChromeButtonStyle(large: true)).keyboardShortcut(.cancelAction)
                Button(L("Continue")) {
                    run {
                        let key = try await account.register(email: email, password: password, keepSignedIn: keepSignedIn)
                        mode = .recoveryKey(key.displayString)
                    }
                }
                .buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!emailIsPlausible || PasswordStrength.score(password) < 2 || confirm != password)
            }
        }
    }

    // "Forgot password?": recovery key + new password.
    private var forgot: some View {
        Group {
            header("key", L("Use your recovery key"),
                   L("Enter the recovery key you saved when you created the account, then choose a new password."))
            field("envelope", L("Email"), $email)
            field("key", "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", $recoveryKey)
                .font(.custom("Menlo", size: 12))
            field("lock", L("New password"), $password, secure: true)
            PasswordStrength(password: password)
            field("lock.rotation", L("Confirm new password"), $confirm, secure: true)
            errorLine
            HStack {
                Button(L("Back to sign in")) { mode = .signIn; error = nil }.buttonStyle(.link)
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Cancel"), action: dismiss).buttonStyle(ChromeButtonStyle(large: true)).keyboardShortcut(.cancelAction)
                Button(L("Reset password")) {
                    run {
                        try await account.recover(email: email, recoveryKey: recoveryKey, newPassword: password, keepSignedIn: keepSignedIn)
                        mode = .restored
                    }
                }
                .buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(!emailIsPlausible || recoveryKey.count < 32 || PasswordStrength.score(password) < 2 || confirm != password)
            }
        }
    }

    // A3
    private func recovery(_ key: String, purpose: RecoveryKeyPurpose) -> some View {
        let groups = key.split(separator: "-").map(String.init)
        let profiles = (account.local.config.user["profiles"]?.arrayValue ?? []).count
        let texts = RecoveryKeyTexts(purpose: purpose, profiles: profiles)
        return Group {
            header("key.fill", texts.title, texts.message, step: texts.step)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    Text(g).font(.custom("Menlo", size: 15).weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                        .background(RoundedRectangle(cornerRadius: 6).fill(chrome.surface.color))
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string) } label: {
                    Label(L("Copy"), systemImage: "doc.on.doc")
                }
                Button { RecoveryKeyExport.save(key) } label: { Label(L("Save as file…"), systemImage: "arrow.down.doc") }
                Button { RecoveryKeyExport.print(key) } label: { Label(L("Print"), systemImage: "printer") }
            }
            .buttonStyle(ChromeButtonStyle())
            if texts.needsSavedConfirmation {
                Toggle(L("I've stored the recovery key somewhere safe"), isOn: $savedKey).toggleStyle(.checkbox)
            }
            HStack {
                if let footer = texts.footer {
                    Text(footer).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                }
                Spacer()
                Button(texts.confirm) {
                    if purpose == .signUp { Task { await account.finishRegistration() } }
                    dismiss()
                }
                .buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(texts.needsSavedConfirmation && !savedKey)
            }
        }
    }

    // A8
    private var restored: some View {
        let c = account.counts
        let failed: String? = { if case .failed(let m) = account.status { return m } else { return nil } }()
        return Group {
            header("checkmark.icloud", L("Welcome back"),
                   failed ?? L("Your setup is restored from your account. Passwords and keys went into this Mac's Keychain, so your saved servers connect without asking again."))
            VStack(spacing: 0) {
                step("slider.horizontal.3", L("Settings, hotkeys & colour schemes"), L("Done"))
                step("rectangle.stack", L("Profiles & connections"), "\(c.profiles)")
                step("key", L("Passwords & private keys"), Plural.count(c.passwords, one: "1 password", other: "{n} passwords") + " · " + Plural.count(c.keys, one: "1 key", other: "{n} keys"))
                step("checkmark.shield", L("Known hosts"), L("Done"))
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(chrome.surface.color))
            HStack {
                Spacer()
                Button(L("Open profiles")) {
                    dismiss()
                    _ = WindowManager.shared.activeController?.runCommand("profile-selector")
                }
                .buttonStyle(ChromeButtonStyle(large: true))
                Button(L("Done"), action: dismiss).buttonStyle(ChromeButtonStyle(kind: .primary, large: true)).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func step(_ symbol: String, _ label: String, _ meta: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(chrome.textMuted.color)
            Text(label)
            Spacer()
            Text(meta).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
            Image(systemName: "checkmark.circle.fill").foregroundStyle(chrome.success.color)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }
}

/// A four-step strength meter (length and character variety).
struct PasswordStrength: View {
    let password: String
    @Environment(\.chrome) private var chrome

    static func score(_ p: String) -> Int {
        guard !p.isEmpty else { return 0 }
        var classes = 0
        if p.contains(where: \.isLowercase) { classes += 1 }
        if p.contains(where: \.isUppercase) { classes += 1 }
        if p.contains(where: \.isNumber) { classes += 1 }
        if p.contains(where: { !$0.isLetter && !$0.isNumber }) { classes += 1 }
        switch p.count {
        case ..<8: return 1
        case 8..<12: return classes >= 3 ? 3 : 2
        default: return classes >= 2 ? 4 : 3
        }
    }

    var body: some View {
        let score = Self.score(password)
        let label = ["", L("Too short"), L("Fair"), L("Good"), L("Strong")][score]
        let tint = score >= 3 ? chrome.success : (score == 2 ? chrome.warning : chrome.danger)
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule().fill((i < score ? tint : chrome.fillStrong).color).frame(height: 4)
                }
            }
            .frame(width: 120)
            Text(password.isEmpty ? L("At least 8 characters; a password manager suggestion is fine.") : "\(label) · " + Plural.count(password.count, one: "1 character", other: "{n} characters"))
                .font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
        }
    }
}

/// Save as file… and Print for the recovery key.
@MainActor
enum RecoveryKeyExport {
    static func text(_ key: String) -> String {
        L("TabbyMac recovery key") + "\n\n" + key + "\n\n"
            + L("Keep this somewhere safe. With your email address it unlocks your synced profiles, passwords and private keys if you forget your password.") + "\n"
    }

    static func save(_ key: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L("TabbyMac Recovery Key") + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text(key).write(to: url, atomically: true, encoding: .utf8)
    }

    static func print(_ key: String) {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 240))
        view.string = text(key)
        view.font = NSFont(name: "Menlo", size: 13)
        NSPrintOperation(view: view).run()
    }
}

// MARK: - Key files, sign out

/// Asks once per private key before it is uploaded (the owner's choice: ssh's default
/// identities included, one confirmation per key).
struct KeyFilesSheet: View {
    let files: [KeyFileCandidate]
    let dismiss: () -> Void
    @State private var selected: Set<String>
    @Environment(\.chrome) private var chrome

    init(files: [KeyFileCandidate], dismiss: @escaping () -> Void) {
        self.files = files
        self.dismiss = dismiss
        _selected = State(initialValue: Set(files.map(\.id)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "key").font(.system(size: 18)).foregroundStyle(chrome.warning.color)
                    .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 8).fill(chrome.warning.withAlpha(0.18).color))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Upload private keys to your account?")).font(ChromeFont.headline)
                    Text(L("Your other Macs need these to connect without setup. They are encrypted on this Mac first; the server can't read them."))
                        .font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(spacing: 0) {
                ForEach(files) { f in
                    Toggle(isOn: Binding(get: { selected.contains(f.id) },
                                         set: { if $0 { selected.insert(f.id) } else { selected.remove(f.id) } })) {
                        HStack {
                            Text(f.originalPath).font(.custom("Menlo", size: 12))
                            if f.isDefaultIdentity {
                                Text(L("default identity")).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 12)
                    .frame(height: 32, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(chrome.surface.color))
            Text(L("You can change this later in Settings › Account & sync.")).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
            HStack {
                Spacer()
                Button(L("Don't upload")) {
                    AppServices.shared.account.decideKeyFiles(approve: [], decline: files.map(\.id))
                    dismiss()
                }
                .buttonStyle(ChromeButtonStyle(large: true))
                .keyboardShortcut(.cancelAction)
                Button(selected.isEmpty ? L("Continue") : L("Upload {selectedCount}", ["selectedCount": selected.count])) {
                    AppServices.shared.account.decideKeyFiles(approve: Array(selected), decline: files.map(\.id).filter { !selected.contains($0) })
                    dismiss()
                }
                .buttonStyle(ChromeButtonStyle(kind: .primary, large: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
    }
}

/// The design's A9.
struct SignOutSheet: View {
    let dismiss: () -> Void
    @State private var removeData = false
    @State private var working = false
    @Environment(\.chrome) private var chrome

    var body: some View {
        let account = AppServices.shared.account
        let c = account.removableCounts
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.and.arrow.right").font(.system(size: 17)).foregroundStyle(chrome.accent.color)
                    .frame(width: 36, height: 36).background(RoundedRectangle(cornerRadius: 8).fill(chrome.accentFill.color))
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Sign out of TabbyMac?")).font(ChromeFont.headline)
                    Text(L("Syncing stops on this Mac. Your data stays in your account.")).font(ChromeFont.callout)
                        .foregroundStyle(chrome.textMuted.color)
                }
            }
            choice(false, L("Keep a local copy"), L("Profiles and keys stay usable here, unsynced"))
            choice(true, L("Remove synced data from this Mac"),
                   L("Deletes the {profiles}, {passwords} and {keys} that came from your account; what was made on this Mac stays", ["profiles": Plural.count(c.profiles, one: "1 profile", other: "{n} profiles"), "passwords": Plural.count(c.passwords, one: "1 password", other: "{n} passwords"), "keys": Plural.count(c.keys, one: "1 key", other: "{n} keys")]))
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Cancel"), action: dismiss).buttonStyle(ChromeButtonStyle(large: true)).keyboardShortcut(.cancelAction)
                Button(L("Sign out")) {
                    working = true
                    Task {
                        await account.signOut(removeSyncedData: removeData)
                        dismiss()
                    }
                }
                .buttonStyle(ChromeButtonStyle(kind: removeData ? .destructive : .primary, large: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .disabled(working)
    }

    private func choice(_ value: Bool, _ title: String, _ detail: String) -> some View {
        Button { removeData = value } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: removeData == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle((removeData == value ? chrome.accent : chrome.textMuted).color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ChromeFont.bodyEmphasised)
                    Text(detail).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(chrome.surface.color))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(removeData == value ? chrome.accent.color : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
#endif
