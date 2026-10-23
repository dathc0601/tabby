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
    /// When the current session started (the "Process completed" toast shows how long it ran).
    public private(set) var startedAt: Date?
    /// Automatic reconnects since the connection was last up (profile "Reconnect" behaviour).
    public private(set) var reconnectAttempt = 0
    public static let maxReconnectAttempts = 5
    /// Pause before the first automatic reconnect; later attempts double it (up to 30 s).
    public var reconnectDelay: TimeInterval = 1

    public static func reconnectDelay(base: TimeInterval, attempt: Int) -> TimeInterval {
        min(base * pow(2, Double(max(attempt, 1) - 1)), 30)
    }

    /// What the SSH status chip shows; nil for local shells.
    public enum ConnectionState: Equatable, Sendable {
        case connecting
        case connected
        case disconnected
        case reconnecting(attempt: Int, of: Int)
    }

    public var connectionState: ConnectionState? {
        guard profile.type != "local" else { return nil }
        let reconnecting = ConnectionState.reconnecting(attempt: reconnectAttempt, of: Self.maxReconnectAttempts)
        switch state {
        case .idle:
            return reconnectAttempt > 0 ? reconnecting : .connecting
        case .running:
            switch status {
            case .connecting?: return reconnectAttempt > 0 ? reconnecting : .connecting
            case .disconnected?: return .disconnected
            case .connected?: return .connected
            default: return reconnectAttempt > 0 ? reconnecting : .connected
            }
        case .ended, .failed:
            return reconnectAttempt > 0 ? reconnecting : .disconnected
        }
    }
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
    /// Set by `disconnect()`: the session end keeps the pane and waits for a key to reconnect.
    @ObservationIgnored private var disconnectedByHand = false
    @ObservationIgnored private var progressClearWork: DispatchWorkItem?
    @ObservationIgnored private var loginScripts: LoginScriptRunner?
    @ObservationIgnored private let progressDetector = ProgressDetector()
    @ObservationIgnored private var started = false
    /// A restored pane keeps its replayed scrollback when it first connects, even if the
    /// profile clears service messages on connect.
    @ObservationIgnored private var keepsRestoredScrollback = false

    /// Ask the app to close this pane (session ended with close behaviour).
    @ObservationIgnored public var onRequestClose: ((TerminalPane) -> Void)?
    /// Ask the app to show the multi-line paste warning; call `confirmPaste`/`cancelPaste`.
    @ObservationIgnored public var onRequestPasteConfirmation: ((TerminalPane, String) -> Void)?
    @ObservationIgnored public var onBell: ((TerminalPane) -> Void)?
    @ObservationIgnored public var onFocus: ((TerminalPane) -> Void)?
    /// Fired whenever the session ends by itself; the app decides whether to notify
    /// (it does when it is not the active app).
    @ObservationIgnored public var onProcessEnded: ((TerminalPane, Int32?) -> Void)?
    @ObservationIgnored public var onRecoveryStateChanged: (() -> Void)?
    /// Sees keyboard input before it is sent (used for broadcasting to other panes).
    @ObservationIgnored public var onUserInput: ((TerminalPane, Data) -> Void)?
    /// Sees a paste once it is prepared and confirmed (used for broadcasting to other panes).
    @ObservationIgnored public var onPaste: ((TerminalPane, String) -> Void)?

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
        keepsRestoredScrollback = restore?.savedState?.isEmpty == false
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
            s.onStatus = { [weak self] st in
                self?.status = st
                if st == .connected { self?.connected() }
            }
            // Each connection runs the profile's login scripts afresh, as Tabby builds its
            // LoginScriptProcessor per session; every type has them, not just SSH.
            let scripts = (profile.options["scripts"]?.arrayValue ?? []).compactMap(LoginScript.init)
            loginScripts = scripts.isEmpty ? nil : LoginScriptRunner(scripts: scripts)
            session = s
            userClosed = false
            disconnectedByHand = false
            recentInput = ""
            started = true
            try s.start(cols: max(size.cols, 2), rows: max(size.rows, 1))
            // A session can end inside `start` (a serial port that can't open).
            guard session === s else { return }
            startedAt = Date()
            state = .running
            if let scripts = loginScripts?.unconditionalScripts() {
                for line in scripts { s.write(Data(line.utf8)) }
            }
        } catch {
            state = .failed(error.localizedDescription)
            engine?.feed(Data("\r\n".utf8) + ServiceMessage.error(error.localizedDescription))
        }
    }

    private func connected() {
        reconnectAttempt = 0
        // Tabby's `clearServiceMessagesOnConnect` (ConnectableTerminalTabComponent).
        guard profile.type != "local", profile.clearServiceMessagesOnConnect else { return }
        if keepsRestoredScrollback {
            keepsRestoredScrollback = false
            return
        }
        engine?.clearScreen()
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
        reconnectAttempt = 0
        progressClearWork?.cancel()
        session?.onClosed = nil
        session?.onOutput = nil
        session?.kill()
        session = nil
    }

    /// Ends a connection on purpose but keeps the pane, which then offers to reconnect on any
    /// key whatever `behaviorOnSessionEnd` says. Port of Tabby's
    /// `ConnectableTerminalTabComponent.disconnect`; local shells ignore it, as in Tabby.
    public func disconnect() {
        guard profile.type != "local", isRunning, let session else { return }
        disconnectedByHand = true
        reconnectAttempt = 0
        session.kill()
    }

    /// Whether closing should ask first (a program other than the shell is running).
    public var activeProcessName: String? { session?.activeProcessName() }

    /// Why closing this pane should ask first, or nil. A busy child process always asks; an
    /// open SSH connection asks when the profile's `warnOnClose` (else the global
    /// `ssh.warnOnClose`) is on, as in Tabby's `SSHTabComponent.canClose`; an open telnet
    /// connection always asks (`TelnetTabComponent.canClose`).
    public func closeWarning(sshWarnOnClose: Bool) -> String? {
        if let name = activeProcessName { return L("{name} is still running.", ["name": name]) }
        guard isRunning, session != nil else { return nil }
        switch profile.type {
        case "ssh":
            let options = SSHOptions(profile.options)
            guard options.warnOnClose ?? sshWarnOnClose else { return nil }
            return L("Disconnect from {host}?", ["host": options.host])
        case "telnet":
            return L("Disconnect from {host}?", ["host": TelnetOptions(profile.options).host])
        default:
            return nil
        }
    }

    // MARK: Output

    private func handleOutput(_ data: Data) {
        engine?.feed(data)
        if !isFocused && !hasActivity { hasActivity = true }
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
        // Closing a pane by hand ends its process too; that is not news worth a toast.
        if !userClosed { onProcessEnded?(self, code) }

        var shouldClose: Bool
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
        if disconnectedByHand {
            shouldClose = false
            autoReconnect = false
        }

        session = nil
        if shouldClose && !userClosed {
            state = .ended(code: code, canRestart: false)
            onRequestClose?(self)
            return
        }
        // A shell restarts; a connection reconnects (design C9).
        let message: String
        if isLocal {
            message = code.map { L("Process exited with code {code}. Press any key to restart.", ["code": $0]) }
                    ?? L("Process terminated. Press any key to restart.")
        } else {
            message = L("Session closed. Press any key to reconnect.")
        }
        engine?.feed(Data("\r\n\u{1b}[2m\(message)\u{1b}[0m\r\n".utf8))
        state = .ended(code: code, canRestart: true)
        if autoReconnect {
            if reconnectAttempt >= Self.maxReconnectAttempts {
                // Give up; any key still restarts, as after a manual disconnect.
                reconnectAttempt = 0
            } else {
                reconnectAttempt += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.reconnectDelay(base: reconnectDelay, attempt: reconnectAttempt)) { [weak self] in
                    guard let self, case .ended = self.state, self.reconnectAttempt > 0 else { return }
                    self.start()
                }
            }
        }
    }

    /// Tabby treats a session as deliberately ended when the last input was ^D, `exit` or
    /// `logout`; serial and telnet tabs use `close` or `quit` instead.
    private func isExplicitlyTerminated(code: Int32?) -> Bool {
        let tail = recentInput.trimmingCharacters(in: .whitespaces)
        if profile.type == "serial" || profile.type == "telnet" {
            return tail.hasSuffix("close\r") || tail.hasSuffix("quit\r")
        }
        return tail.hasSuffix("\u{04}") || tail.hasSuffix("exit\r") || tail.hasSuffix("logout\r")
    }

    // MARK: Input

    public func send(_ data: Data) {
        if case .ended(_, true) = state {
            reconnectAttempt = 0
            start()
            return
        }
        session?.write(InputProcessing.translate(data, backspace: InputProcessing.backspaceMode(profile.options)))
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
        onPaste?(self, text)
    }

    public func confirmPaste() {
        guard let text = pendingPaste else { return }
        pendingPaste = nil
        sendPaste(text)
        onPaste?(self, text)
    }

    public func cancelPaste() {
        pendingPaste = nil
    }

    /// Sends paste text that is already prepared, bracketed when this pane's program asked for it.
    public func sendPaste(_ text: String) {
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

    /// Changes one option of this pane's copy of the profile without restarting (the serial
    /// rate changed while connected); the recovery token keeps it.
    public func updateOption(_ key: String, _ value: ConfigValue) {
        profile.options[key] = value
        onRecoveryStateChanged?()
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
        // Local tabs reopen where they were; SSH tabs too with rememberCwd (Tabby).
        if let cwd, p.type == "local" || (p.type == "ssh" && SSHOptions(p.options).rememberCwd) {
            p.options["cwd"] = .string(cwd)
        }
        return PaneRecovery(
            type: PaneRecovery.type(forProfileType: profile.type),
            profile: p,
            cwd: cwd,
            savedState: snapshot(fresh: includeBuffer),
            title: dynamicTitle,
            customTitle: customTitle,
            disableDynamicTitle: profile.disableDynamicTitle
        )
    }

    @ObservationIgnored private var lastSnapshot: String?

    /// A fresh buffer snapshot, or the last one taken (snapshots are relatively costly).
    private func snapshot(fresh: Bool) -> String? {
        if fresh, let engine { lastSnapshot = engine.snapshotText(maxLines: 1000) }
        return lastSnapshot ?? restoreState
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
