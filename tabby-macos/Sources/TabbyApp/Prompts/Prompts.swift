#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbySSH

/// Native replacements for Tabby's prompt / rename / confirmation modals.
@MainActor
enum Prompts {
    static func confirm(in window: NSWindow?, title: String, message: String, confirm: String, cancel: String = "Cancel",
                        destructive: Bool = false, completion: @escaping (Bool) -> Void) {
        let alert = confirmAlert(title: title, message: message, confirm: confirm, cancel: cancel, destructive: destructive)
        run(alert, in: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// A destructive confirm has no Return key (design C10): closing a live connection takes a
    /// deliberate click; Cancel keeps Escape.
    static func confirmAlert(title: String, message: String, confirm: String, cancel: String = "Cancel",
                             destructive: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let ok = alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: cancel)
        if destructive {
            ok.hasDestructiveAction = true
            ok.keyEquivalent = ""
        }
        return alert
    }

    /// Tabby's multi-line paste warning, as the design's card.
    static func confirmPaste(in window: NSWindow?, text: String, completion: @escaping (Bool) -> Void) {
        ChromeSheet.present(in: window) { dismiss in
            PasteWarningCard(text: text) { paste, dontAsk in
                dismiss()
                if dontAsk { AppServices.shared.config.set("terminal.warnOnMultilinePaste", false) }
                completion(paste)
            }
        }
    }

    /// A text prompt (Tabby's `PromptModalComponent`). `remember` adds a checkbox.
    static func text(in window: NSWindow?, title: String, message: String = "", value: String = "", secure: Bool = false,
                     remember: String? = nil, confirm: String = "OK", completion: @escaping (String?, Bool) -> Void) {
        ChromeSheet.present(in: window) { dismiss in
            TextPromptCard(symbol: secure ? "lock" : "pencil", title: title, message: message, secure: secure,
                           remember: remember, confirm: confirm, finish: { value, remember in
                               dismiss()
                               completion(value, remember)
                           }, value: value)
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

/// Where a session's question goes: Tabby asks inside the session's own tab, so the card is
/// shown on that tab's window with the tab brought to the front. It never covers (or takes the
/// keys of) another tab or window.
@MainActor
enum PromptPlacement {
    /// For a question: the session's window, with its tab brought to the front.
    static func window(showing session: AnyObject) -> NSWindow? {
        guard let (controller, paneID) = find(session) else { return NSApp.keyWindow ?? NSApp.mainWindow }
        controller.model.focus(paneID: paneID)
        return controller.window
    }

    /// For a notice (a toast): the session's window; the tabs stay as they are.
    static func window(of session: AnyObject) -> NSWindow? {
        find(session)?.controller.window ?? NSApp.keyWindow ?? NSApp.mainWindow
    }

    private static func find(_ session: AnyObject) -> (controller: MainWindowController, paneID: UUID)? {
        for controller in WindowManager.shared.controllers {
            for tab in controller.model.tabs {
                if let pane = tab.panes.values.first(where: { $0.session === session }) {
                    return (controller, pane.id)
                }
            }
        }
        return nil
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
            self.present(prompt, host: host, profileName: profileName, window: PromptPlacement.window(showing: session), reply: reply)
        }
    }

    private func present(_ prompt: AskpassPrompt, host: String, profileName: String, window: NSWindow?,
                         reply: @escaping (SSHPromptReply) -> Void) {
        switch prompt {
        case let .hostKey(promptHost, keyType, fingerprint, _):
            ChromeSheet.present(in: window) { dismiss in
                HostKeyPromptCard(host: promptHost.isEmpty ? host : promptHost, keyType: keyType, fingerprint: fingerprint) { accept in
                    dismiss()
                    reply(accept ? .accept : .reject)
                }
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
