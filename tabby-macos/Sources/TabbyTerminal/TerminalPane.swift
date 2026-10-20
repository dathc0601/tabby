import Foundation
import Observation
import TabbyCore

/// One terminal pane: a session wired to an engine. Port of Tabby's
/// `BaseTerminalTabComponent` + `ConnectableTerminalTabComponent`
/// (`tabby-terminal/src/api/*.ts`). UI-independent; views observe it.
@Observable
public final class TerminalPane: TerminalEngineDelegate {
    public enum State: Equatable {
        case idle
        case running
        /// The session ended; `canRestart` means any key restarts it.
        case ended(code: Int32?, canRestart: Bool)
        case failed(String)
    }

    public let id: UUID
    public private(set) var profile: Profile
    public var settings: TerminalSettings
    public var scheme: ColorScheme

    public private(set) var state: State = .idle
    /// Title set by the running program (OSC 0/2).
    public private(set) var dynamicTitle: String?
    /// Title set by the user (Rename tab/pane).
    public var customTitle: String?
    public private(set) var workingDirectory: String?
    public private(set) var progress: Double?
    public private(set) var hasActivity = false
    public private(set) var status: SessionStatus?
    public var isFocused = false {
        didSet { if isFocused { hasActivity = false } }
    }
    public var fontSize: Double
    /// Text waiting for the user to confirm the multi-line paste warning.
    public private(set) var pendingPaste: String?
    /// Search UI state.
    public var isSearchVisible = false

    @ObservationIgnored public private(set) var session: TerminalSession?
    @ObservationIgnored public private(set) weak var engine: TerminalEngine?
    @ObservationIgnored private let factory: SessionFactory
    @ObservationIgnored private var context: SessionContext
    @ObservationIgnored private var restoreState: String?
    @ObservationIgnored private var recentInput = ""
    @ObservationIgnored private var userClosed = false
    @ObservationIgnored private var progressClearWork: DispatchWorkItem?
    @ObservationIgnored private var loginScripts: LoginScriptRunner?
    @ObservationIgnored private let progressDetector = ProgressDetector()
    @ObservationIgnored private var started = false

    /// Ask the app to close this pane (session ended with close behaviour).
    @ObservationIgnored public var onRequestClose: ((TerminalPane) -> Void)?
    /// Ask the app to show the multi-line paste warning; call `confirmPaste`/`cancelPaste`.
    @ObservationIgnored public var onRequestPasteConfirmation: ((TerminalPane, String) -> Void)?
    @ObservationIgnored public var onBell: ((TerminalPane) -> Void)?
    @ObservationIgnored public var onFocus: ((TerminalPane) -> Void)?
    /// Fired when the session ends while the pane is not focused ("notify when done").
    @ObservationIgnored public var onProcessEnded: ((TerminalPane, Int32?) -> Void)?
    @ObservationIgnored public var onRecoveryStateChanged: (() -> Void)?
    /// Sees keyboard input before it is sent (used for broadcasting to other panes).
    @ObservationIgnored public var onUserInput: ((TerminalPane, Data) -> Void)?

    public init(id: UUID = UUID(), profile: Profile, factory: SessionFactory, context: SessionContext,
                settings: TerminalSettings, scheme: ColorScheme, restore: PaneRecovery? = nil) {
        self.id = id
        self.profile = profile
        self.factory = factory
        self.context = context
        self.settings = settings
        self.scheme = scheme
        self.fontSize = settings.fontSize
        if let restore {
            customTitle = restore.customTitle
            dynamicTitle = restore.title
            restoreState = restore.savedState
            workingDirectory = restore.cwd
            if let cwd = restore.cwd { self.context.workingDirectory = cwd }
        }
        if profile.type == "ssh" {
            let scripts = SSHOptions(profile.options).scripts
            if !scripts.isEmpty { loginScripts = LoginScriptRunner(scripts: scripts) }
        }
    }

    /// The title shown in the tab: custom > dynamic (unless disabled) > profile name.
    public var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !profile.disableDynamicTitle, let dynamicTitle, !dynamicTitle.isEmpty { return dynamicTitle }
        return profile.name
    }

    public var isRunning: Bool { state == .running }

    // MARK: Lifecycle

    public func attach(engine: TerminalEngine) {
        self.engine = engine
        engine.engineDelegate = self
        engine.apply(settings: settings, scheme: scheme, fontSize: fontSize)
        if let saved = restoreState, !saved.isEmpty {
            let text = saved.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
            engine.feed(Data(text.utf8))
            engine.feed(Data("\r\n".utf8))
            restoreState = nil
        }
    }

    /// Starts (or restarts) the session using the engine's current grid size.
    public func start() {
        let size: (cols: Int, rows: Int) = engine?.gridSize ?? (cols: 80, rows: 24)
        do {
            let s = try factory.makeSession(profile: profile, context: context)
            s.onOutput = { [weak self] data in self?.handleOutput(data) }
            s.onClosed = { [weak self] code in self?.handleClosed(code) }
            s.onStatus = { [weak self] st in self?.status = st }
            session = s
            userClosed = false
            recentInput = ""
            try s.start(cols: max(size.cols, 2), rows: max(size.rows, 1))
            state = .running
            started = true
            if let scripts = loginScripts?.unconditionalScripts() {
                for line in scripts { s.write(Data(line.utf8)) }
            }
        } catch {
            state = .failed(error.localizedDescription)
            engine?.feed(Data("\r\n\u{1b}[31m\(error.localizedDescription)\u{1b}[0m\r\n".utf8))
        }
    }

    /// Starts the session once the view has laid out (no-op if already started).
    public func startIfNeeded() {
        guard !started, state == .idle else { return }
        start()
    }

    public var hasStarted: Bool { started }

    public func restart() {
        session?.onClosed = nil
        session?.kill()
        session = nil
        engine?.feed(Data("\r\n".utf8))
        start()
    }

    /// Ends the session on purpose (closing the pane).
    public func close() {
        userClosed = true
        progressClearWork?.cancel()
        session?.onClosed = nil
        session?.onOutput = nil
        session?.kill()
        session = nil
    }

    /// Whether closing should ask first (a program other than the shell is running).
    public var activeProcessName: String? { session?.activeProcessName() }

    // MARK: Output

    private func handleOutput(_ data: Data) {
        engine?.feed(data)
        if !isFocused { hasActivity = true }
        let needsText = settings.detectProgress || loginScripts?.isDone == false
        guard needsText else { return }
        let text = String(decoding: data, as: UTF8.self)
        if settings.detectProgress, !(engine?.isAlternateScreen ?? false), let p = progressDetector.detect(in: text) {
            setProgress(p)
        }
        if let runner = loginScripts, !runner.isDone {
            for line in runner.process(text) { session?.write(Data(line.utf8)) }
        }
    }

    private func setProgress(_ value: Double?) {
        progress = value
        progressClearWork?.cancel()
        guard value != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.progress = nil }
        progressClearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func handleClosed(_ code: Int32?) {
        progress = nil
        let explicit = isExplicitlyTerminated(code: code)
        let behaviour = profile.behaviorOnSessionEnd
        let isLocal = profile.type == "local"
        let pause = isLocal && LocalOptions(profile.options).pauseAfterExit
        if !isFocused { onProcessEnded?(self, code) }

        let shouldClose: Bool
        var autoReconnect = false
        switch behaviour {
        case .close: shouldClose = true
        case .keep: shouldClose = false
        case .reconnect:
            shouldClose = false
            autoReconnect = !userClosed
        case .auto:
            shouldClose = isLocal ? !pause : explicit
        }

        session = nil
        if shouldClose && !userClosed {
            state = .ended(code: code, canRestart: false)
            onRequestClose?(self)
            return
        }
        let message: String
        if isLocal {
            message = code.map { "Process exited with code \($0)" } ?? "Process terminated"
        } else {
            message = "Session closed"
        }
        engine?.feed(Data("\r\n\u{1b}[2m\(message). Press any key to restart.\u{1b}[0m\r\n".utf8))
        state = .ended(code: code, canRestart: true)
        if autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, case .ended = self.state else { return }
                self.start()
            }
        }
    }

    /// Tabby treats a session as deliberately ended when the last input was ^D or `exit`.
    private func isExplicitlyTerminated(code: Int32?) -> Bool {
        let tail = recentInput.trimmingCharacters(in: .whitespaces)
        return tail.hasSuffix("\u{04}") || tail.hasSuffix("exit\r") || tail.hasSuffix("logout\r")
    }

    // MARK: Input

    public func send(_ data: Data) {
        if case .ended(_, true) = state {
            start()
            return
        }
        session?.write(data)
        if settings.scrollOnInput { engine?.scroll(.bottom) }
        if let s = String(data: data, encoding: .utf8) {
            recentInput = String((recentInput + s).suffix(16))
        }
    }

    public func send(text: String) {
        send(Data(text.utf8))
    }

    /// Pastes with Tabby's preprocessing, asking first for multi-line text.
    public func paste(_ raw: String) {
        let text = PastePreparation.prepare(raw, trimWhitespace: settings.trimWhitespaceOnPaste,
                                            replaceNewlinesWithSpaces: settings.replaceNewlinesWithSpacesOnPaste)
        guard !text.isEmpty else { return }
        if PastePreparation.needsMultilineWarning(text, enabled: settings.warnOnMultilinePaste,
                                                  alternateScreen: engine?.isAlternateScreen ?? false),
           let ask = onRequestPasteConfirmation {
            pendingPaste = text
            ask(self, text)
            return
        }
        sendPaste(text)
    }

    public func confirmPaste() {
        guard let text = pendingPaste else { return }
        pendingPaste = nil
        sendPaste(text)
    }

    public func cancelPaste() {
        pendingPaste = nil
    }

    private func sendPaste(_ text: String) {
        let bracketed = settings.bracketedPaste && (engine?.isBracketedPasteMode ?? false)
        send(text: PastePreparation.bracketed(text, enabled: bracketed))
    }

    // MARK: Appearance

    public func applyAppearance(settings: TerminalSettings, scheme: ColorScheme) {
        let fontChanged = settings.fontSize != self.settings.fontSize
        self.settings = settings
        self.scheme = scheme
        if fontChanged { fontSize = settings.fontSize }
        engine?.apply(settings: settings, scheme: scheme, fontSize: fontSize)
    }

    public func zoom(by delta: Double) {
        fontSize = min(max(fontSize + delta, 6), 72)
        engine?.apply(settings: settings, scheme: scheme, fontSize: fontSize)
    }

    public func resetZoom() {
        fontSize = settings.fontSize
        engine?.apply(settings: settings, scheme: scheme, fontSize: fontSize)
    }

    /// Switches the pane to another profile (Tabby's "switch profile"), restarting it.
    public func switchProfile(_ newProfile: Profile) {
        profile = newProfile
        restart()
    }

    // MARK: Recovery

    public func recoveryState(includeBuffer: Bool = true) -> PaneRecovery {
        var p = profile
        let cwd = session?.workingDirectory() ?? workingDirectory
        if let cwd, p.type == "local" { p.options["cwd"] = .string(cwd) }
        return PaneRecovery(
            type: PaneRecovery.type(forProfileType: profile.type),
            profile: p,
            cwd: cwd,
            savedState: includeBuffer ? engine?.snapshotText(maxLines: 1000) : nil,
            title: dynamicTitle,
            customTitle: customTitle,
            disableDynamicTitle: profile.disableDynamicTitle
        )
    }

    /// Current directory for new panes/tabs opened from this one.
    public func currentDirectory() -> String? {
        session?.workingDirectory() ?? workingDirectory
    }

    // MARK: TerminalEngineDelegate

    public func engine(_ engine: TerminalEngine, send data: Data) {
        onUserInput?(self, data)
        send(data)
    }

    public func engine(_ engine: TerminalEngine, resized cols: Int, rows: Int) {
        session?.resize(cols: cols, rows: rows)
        if !started, state == .idle { start() }
    }

    public func engine(_ engine: TerminalEngine, titleChanged title: String) {
        dynamicTitle = title
        onRecoveryStateChanged?()
    }

    public func engine(_ engine: TerminalEngine, directoryChanged directory: String?) {
        guard let directory else { return }
        // OSC 7 sends file://host/path
        if let url = URL(string: directory), url.isFileURL {
            workingDirectory = url.path
        } else {
            workingDirectory = directory
        }
        onRecoveryStateChanged?()
    }

    public func engineBell(_ engine: TerminalEngine) {
        onBell?(self)
    }

    public func engineDidFocus(_ engine: TerminalEngine) {
        onFocus?(self)
    }

    public func engine(_ engine: TerminalEngine, paste text: String) {
        paste(text)
    }

    public func engineSelectionChanged(_ engine: TerminalEngine) {}
}
