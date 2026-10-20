#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbySSH

/// Native replacements for Tabby's prompt / rename / confirmation modals.
@MainActor
enum Prompts {
    static func confirm(in window: NSWindow?, title: String, message: String, confirm: String, cancel: String = "Cancel",
                        destructive: Bool = false, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        if destructive { ok.hasDestructiveAction = true }
        run(alert, in: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// Tabby's multi-line paste warning.
    static func confirmPaste(in window: NSWindow?, text: String, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Paste multiple lines?"
        let preview = text.count > 1000 ? String(text.prefix(1000)) + "…" : text
        alert.informativeText = preview.replacingOccurrences(of: "\r", with: "\n")
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        run(alert, in: window) { response in
            if alert.suppressionButton?.state == .on {
                AppServices.shared.config.set("terminal.warnOnMultilinePaste", false)
            }
            completion(response == .alertFirstButtonReturn)
        }
    }

    /// A text prompt (Tabby's `PromptModalComponent`). `remember` adds a checkbox.
    static func text(in window: NSWindow?, title: String, message: String = "", value: String = "", secure: Bool = false,
                     remember: String? = nil, confirm: String = "OK", completion: @escaping (String?, Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        let field: NSTextField = secure ? NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
                                        : NSTextField(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        var checkbox: NSButton?
        if let remember {
            let stack = NSStackView(frame: CGRect(x: 0, y: 0, width: 300, height: 52))
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 8
            let box = NSButton(checkboxWithTitle: remember, target: nil, action: nil)
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(box)
            field.widthAnchor.constraint(equalToConstant: 300).isActive = true
            checkbox = box
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }
        alert.window.initialFirstResponder = field
        run(alert, in: window) { response in
            guard response == .alertFirstButtonReturn else { return completion(nil, false) }
            completion(field.stringValue, checkbox?.state == .on)
        }
    }

    static func message(in window: NSWindow?, title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        run(alert, in: window) { _ in }
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(response) }
            }
        } else {
            completion(alert.runModal())
        }
    }
}

/// Shows SSH prompts (host key, passwords, keyboard-interactive) as sheets on the window
/// that owns the session (Tabby's `HostKeyPromptModal` and keyboard-interactive panel).
@MainActor
final class SSHPromptPresenter: SSHPromptHandler {
    static let shared = SSHPromptPresenter()

    nonisolated func sshSession(_ session: SSHSession, needs prompt: AskpassPrompt, reply: @escaping (SSHPromptReply) -> Void) {
        let host = session.options.host
        let profileName = session.profile.name
        MainActor.assumeIsolated {
            self.present(prompt, host: host, profileName: profileName, reply: reply)
        }
    }

    private func present(_ prompt: AskpassPrompt, host: String, profileName: String, reply: @escaping (SSHPromptReply) -> Void) {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        switch prompt {
        case let .hostKey(promptHost, keyType, fingerprint, _):
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Unknown host key for \(promptHost.isEmpty ? host : promptHost)"
            alert.informativeText = """
            The authenticity of this host can't be established.

            \(keyType ?? "Host") key fingerprint:
            \(fingerprint ?? "unknown")

            Accept it only if you trust this host. The key will be remembered.
            """
            alert.addButton(withTitle: "Accept and remember")
            alert.addButton(withTitle: "Disconnect")
            if let window, window.attachedSheet == nil {
                alert.beginSheetModal(for: window) { r in reply(r == .alertFirstButtonReturn ? .accept : .reject) }
            } else {
                reply(alert.runModal() == .alertFirstButtonReturn ? .accept : .reject)
            }
        case let .password(user, promptHost):
            Prompts.text(in: window, title: "Password for \(user)@\(promptHost)", message: profileName, secure: true,
                         remember: "Remember in Keychain", confirm: "Log in") { value, remember in
                reply(value.map { .text($0, remember: remember) } ?? .cancel)
            }
        case let .passphrase(keyPath):
            Prompts.text(in: window, title: "Passphrase for key", message: keyPath, secure: true,
                         remember: "Remember in Keychain", confirm: "Unlock") { value, remember in
                reply(value.map { .text($0, remember: remember) } ?? .cancel)
            }
        case let .confirm(message):
            Prompts.confirm(in: window, title: host, message: message, confirm: "Yes", cancel: "No") { ok in
                reply(ok ? .accept : .reject)
            }
        case let .secret(message), let .hostKeyChanged(message):
            Prompts.text(in: window, title: host, message: message, secure: true, confirm: "Send") { value, _ in
                reply(value.map { .text($0, remember: false) } ?? .cancel)
            }
        case let .information(message):
            Prompts.message(in: window, title: host, message: message)
            reply(.accept)
        }
    }
}
#endif
