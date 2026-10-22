#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbySSHLib
import TabbyTerminal

/// Answers the library backend's questions with the app's cards, on the window that shows
/// the session.
@MainActor
final class LibSSHPromptPresenter: SSHSessionUI {
    static let shared = LibSSHPromptPresenter()

    /// The window whose tab holds the pane running `session`.
    func window(for session: LibSSHSession) -> NSWindow? {
        for controller in WindowManager.shared.controllers {
            for tab in controller.model.tabs where tab.panes.values.contains(where: { $0.session === session }) {
                return controller.window
            }
        }
        return NSApp.keyWindow ?? NSApp.mainWindow
    }

    func verifyHostKey(_ request: HostKeyRequest, for session: LibSSHSession) async -> HostKeyDecision {
        await verifyHostKey(request, in: window(for: session))
    }

    func verifyHostKey(_ request: HostKeyRequest, in window: NSWindow?) async -> HostKeyDecision {
        let host = request.port == 22 ? request.host : "\(request.host):\(request.port)"
        return await withCheckedContinuation { continuation in
            ChromeSheet.present(in: window) { dismiss in
                HostKeyPromptCard(request: request, host: host) { decision in
                    dismiss()
                    continuation.resume(returning: decision)
                }
            }
        }
    }

    func password(user: String, host: String, for session: LibSSHSession) async -> SecretAnswer? {
        await text(in: window(for: session), title: "Password for \(user)@\(host)", message: session.profile.name,
                   remember: "Remember in Keychain", confirm: "Log in")
    }

    func passphrase(keyPath: String, for session: LibSSHSession) async -> SecretAnswer? {
        await text(in: window(for: session), title: "Passphrase for key", message: keyPath, remember: "Remember in Keychain",
                   confirm: "Unlock")
    }

    /// The pane running `session`.
    func pane(for session: LibSSHSession) -> TerminalPane? {
        for controller in WindowManager.shared.controllers {
            for tab in controller.model.tabs {
                if let pane = tab.panes.values.first(where: { $0.session === session }) { return pane }
            }
        }
        return nil
    }

    /// In the pane's inline panel (design `sshAuth`); one sheet per prompt when the session
    /// has no pane.
    func keyboardInteractive(_ round: KeyboardInteractiveRound, for session: LibSSHSession) async -> KeyboardInteractiveAnswer? {
        if let pane = pane(for: session) {
            return await KeyboardInteractivePanels.shared.ask(round, in: pane.id)
        }
        return await keyboardInteractive(round, in: window(for: session))
    }

    /// One sheet per prompt (no pane to show the panel in).
    func keyboardInteractive(_ round: KeyboardInteractiveRound, in window: NSWindow?) async -> KeyboardInteractiveAnswer? {
        var answers: [String] = []
        var remember = false
        for (index, prompt) in round.prompts.enumerated() {
            let message = [round.instruction, prompt.text].filter { !$0.isEmpty }.joined(separator: "\n")
            guard let answer = await text(in: window, title: round.name.isEmpty ? round.host : round.name, message: message,
                                          secure: !prompt.echo, remember: prompt.isPasswordLike ? "Remember in Keychain" : nil,
                                          value: round.prefilled[index] ?? "", confirm: "Continue") else { return nil }
            answers.append(answer.value)
            remember = remember || answer.remember
        }
        return KeyboardInteractiveAnswer(answers: answers, remember: remember)
    }

    func notify(title: String, detail: String, isError: Bool, for session: LibSSHSession) {
        let window = window(for: session)
        let controller = WindowManager.shared.controllers.first { $0.window === window } ?? WindowManager.shared.activeController
        controller?.toasts.show(ToastCenter.Toast(symbol: "point.3.connected.trianglepath.dotted", tint: isError ? .danger : .success,
                                                  title: title, detail: detail))
    }

    func username(host: String, for session: LibSSHSession) async -> String? {
        await text(in: window(for: session), title: "Username for \(host)", message: session.profile.name, secure: false,
                   confirm: "Continue")?.value
    }

    func text(in window: NSWindow?, title: String, message: String, secure: Bool = true, remember: String? = nil,
                      value: String = "", confirm: String) async -> SecretAnswer? {
        await withCheckedContinuation { continuation in
            Prompts.text(in: window, title: title, message: message, value: value, secure: secure, remember: remember,
                         confirm: confirm) { text, remembered in
                continuation.resume(returning: text.map { SecretAnswer(value: $0, remember: remembered) })
            }
        }
    }
}
/// Answers a connection's questions on one window (the profile editor's Test connection).
@MainActor
final class WindowPrompter: SSHConnectionPrompter {
    private weak var window: NSWindow?

    init(window: NSWindow?) {
        self.window = window
    }

    func verifyHostKey(_ request: HostKeyRequest) async -> HostKeyDecision {
        await LibSSHPromptPresenter.shared.verifyHostKey(request, in: window)
    }

    func password(user: String, host: String) async -> SecretAnswer? {
        await LibSSHPromptPresenter.shared.text(in: window, title: "Password for \(user)@\(host)", message: "",
                                                remember: "Remember in Keychain", confirm: "Log in")
    }

    func passphrase(keyPath: String) async -> SecretAnswer? {
        await LibSSHPromptPresenter.shared.text(in: window, title: "Passphrase for key", message: keyPath,
                                                remember: "Remember in Keychain", confirm: "Unlock")
    }

    func keyboardInteractive(_ round: KeyboardInteractiveRound) async -> KeyboardInteractiveAnswer? {
        await LibSSHPromptPresenter.shared.keyboardInteractive(round, in: window)
    }

    func username(host: String) async -> String? {
        await LibSSHPromptPresenter.shared.text(in: window, title: "Username for \(host)", message: "", secure: false,
                                                confirm: "Continue")?.value
    }

    func message(_ text: String) {}
}
#endif
