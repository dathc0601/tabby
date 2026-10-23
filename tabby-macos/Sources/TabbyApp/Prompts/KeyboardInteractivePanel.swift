#if canImport(AppKit)
import AppKit
import Observation
import SwiftUI
import TabbyCore
import TabbySSHLib

/// One keyboard-interactive round shown in the pane (design `sshAuth`; Tabby's
/// `KeyboardInteractiveAuthComponent`): a prompt at a time, Back keeps answers.
@Observable
@MainActor
final class KeyboardInteractiveModel {
    let round: KeyboardInteractiveRound
    private(set) var index = 0
    private var answers: [String]
    var remember = false
    private var finish: ((KeyboardInteractiveAnswer?) -> Void)?

    init(round: KeyboardInteractiveRound, finish: @escaping (KeyboardInteractiveAnswer?) -> Void) {
        self.round = round
        answers = round.prompts.indices.map { round.prefilled.indices.contains($0) ? round.prefilled[$0] ?? "" : "" }
        self.finish = finish
    }

    private var prompt: KeyboardInteractiveRound.Prompt { round.prompts[index] }

    var answer: String {
        get { answers[index] }
        set { answers[index] = newValue }
    }

    var promptText: String { prompt.text }
    var counter: String { "keyboard-interactive · prompt \(index + 1) of \(round.prompts.count)" }
    var isSecure: Bool { !prompt.echo }
    var showsRemember: Bool { prompt.isPasswordLike }
    var canGoBack: Bool { index > 0 }
    var isLast: Bool { index == round.prompts.count - 1 }

    /// `http(s)` links in the instruction, trailing punctuation trimmed (Tabby).
    var links: [URL] {
        round.instruction.split(whereSeparator: \.isWhitespace).compactMap { word -> URL? in
            guard word.hasPrefix("http://") || word.hasPrefix("https://") else { return nil }
            let trimmed = String(word).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>\"'"))
            return URL(string: trimmed)
        }
    }

    func proceed() {
        guard finish != nil else { return }
        if isLast {
            answer(KeyboardInteractiveAnswer(answers: answers, remember: remember))
        } else {
            index += 1
        }
    }

    func goBack() {
        if index > 0 { index -= 1 }
    }

    func cancel() {
        answer(nil)
    }

    private func answer(_ result: KeyboardInteractiveAnswer?) {
        guard let finish else { return }
        self.finish = nil
        finish(result)
    }
}

/// The strip docked at the top of the pane; it pushes the terminal down. Hosted directly in
/// an NSHostingView, so it feeds the live theme to its content. The pane puts the keys in its
/// field (`PaneContainerView.focusField`): SwiftUI focus state does not reach an AppKit host.
struct KeyboardInteractivePanel: View {
    let model: KeyboardInteractiveModel

    var body: some View {
        KeyboardInteractiveContent(model: model).chromeEnvironment()
    }
}

private struct KeyboardInteractiveContent: View {
    @Bindable var model: KeyboardInteractiveModel
    @Environment(\.chrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "lock").foregroundStyle(chrome.accent.color)
                Text(model.round.host).font(ChromeFont.body.weight(.semibold))
                Text(model.counter).font(ChromeFont.caption).foregroundStyle(chrome.textMuted.color)
                Spacer()
            }
            if !model.round.instruction.isEmpty {
                Text(instruction).font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color).textSelection(.enabled)
            }
            HStack(spacing: 10) {
                Text(model.promptText).font(ChromeFont.body)
                Group {
                    if model.isSecure {
                        SecureField("Response", text: $model.answer)
                    } else {
                        TextField("Response", text: $model.answer)
                    }
                }
                .font(.custom("Menlo", size: 12))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .onSubmit { model.proceed() }
                if model.showsRemember {
                    Toggle("Remember", isOn: $model.remember).toggleStyle(.switch).controlSize(.mini)
                }
                Spacer()
                if model.canGoBack {
                    Button("Back") { model.goBack() }.buttonStyle(ChromeButtonStyle())
                }
                Button("Cancel") { model.cancel() }.buttonStyle(ChromeButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Continue") { model.proceed() }.buttonStyle(ChromeButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceChrome.color)
        .overlay(alignment: .bottom) { Rectangle().fill(chrome.accent.color).frame(height: 2) }
    }

    /// The instruction as written, with its links clickable.
    private var instruction: AttributedString {
        var text = AttributedString(model.round.instruction)
        for url in model.links {
            if let range = text.range(of: url.absoluteString) { text[range].link = url }
        }
        return text
    }
}

/// Open keyboard-interactive rounds by pane, for the pane views to show.
@Observable
@MainActor
final class KeyboardInteractivePanels {
    static let shared = KeyboardInteractivePanels()
    private(set) var models: [UUID: KeyboardInteractiveModel] = [:]
    /// Which session asked, so its end can cancel the question (its pane may be gone by then).
    @ObservationIgnored private var owners: [UUID: ObjectIdentifier] = [:]

    /// Shows the round in the pane and waits for the answer (nil: cancelled).
    func ask(_ round: KeyboardInteractiveRound, in paneID: UUID, owner: ObjectIdentifier) async -> KeyboardInteractiveAnswer? {
        await withCheckedContinuation { continuation in
            models[paneID]?.cancel()
            let model = KeyboardInteractiveModel(round: round) { [weak self] answer in
                self?.models[paneID] = nil
                self?.owners[paneID] = nil
                continuation.resume(returning: answer)
            }
            models[paneID] = model
            owners[paneID] = owner
        }
    }

    /// Cancels the questions of a session that ended.
    func cancel(owner: ObjectIdentifier) {
        for (paneID, id) in owners where id == owner {
            models[paneID]?.cancel()
        }
    }
}
#endif
