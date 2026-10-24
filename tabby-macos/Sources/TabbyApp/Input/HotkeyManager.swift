#if canImport(AppKit)
import AppKit
import Carbon.HIToolbox
import TabbyCore

/// Watches key events before they reach the terminal and runs bound commands
/// (Tabby's `HotkeysService`). Only events that complete or continue a binding are
/// swallowed; everything else goes to the focused view.
@MainActor
final class HotkeyManager {
    private var monitor: Any?
    private var flagsMonitor: Any?
    private let matcher = HotkeyMatcher()
    /// Commands bound to modifiers held on their own, active while held (Tabby's
    /// `hotkey$` / `hotkeyOff$`).
    static let modifierOnlyCommands: Set<String> = ["rearrange-panes"]
    /// A modifier-only command started (true) or ended (false).
    var onModifierHotkey: ((String, Bool) -> Void)?
    private var heldModifierHotkey: String?
    private let run: (String) -> Bool
    /// Pauses matching (while the hotkey capture sheet is open).
    var isSuspended = false

    /// - Parameter run: performs a command id; returns false when it isn't applicable.
    init(run: @escaping (String) -> Bool) {
        self.run = run
    }

    func reload(from config: ConfigStore) {
        var bindings = HotkeyMatcher.bindings(fromHotkeysConfig: config.value("hotkeys"))
        bindings["toggle-window"] = nil  // registered system-wide by GlobalHotkey
        matcher.setBindings(bindings)
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.flagsChanged(event)
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        monitor = nil
        flagsMonitor = nil
    }

    /// A modifier key in a terminal window; text fields keep their keys (as for key-downs).
    func flagsChanged(_ event: NSEvent) {
        guard !isSuspended, event.window is TerminalWindow else { return }
        if event.window?.firstResponder is NSText {
            otherKeyPressed()
            return
        }
        modifiersChanged(event.modifierFlags)
    }

    /// Modifiers pressed or released: starts or ends a modifier-only command.
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        var mods: Keystroke.Modifiers = []
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.shift) { mods.insert(.shift) }
        let id = matcher.modifierOnlyMatch(mods, among: Self.modifierOnlyCommands)
        guard id != heldModifierHotkey else { return }
        if let held = heldModifierHotkey { onModifierHotkey?(held, false) }
        heldModifierHotkey = id
        if let id { onModifierHotkey?(id, true) }
    }

    /// Another key while a modifier-only command is held ends it (the chord no longer matches).
    func otherKeyPressed() {
        guard let held = heldModifierHotkey else { return }
        heldModifierHotkey = nil
        onModifierHotkey?(held, false)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if isSuspended { return event }
        otherKeyPressed()
        // Terminal commands only apply to terminal windows (and their selector panel).
        guard event.window is TerminalWindow else { return event }
        // Text fields (settings, selector, prompts) keep their own shortcuts.
        // (Tabby likewise ignores hotkeys while an <input> has focus.)
        if event.window?.firstResponder is NSText { return event }
        guard let stroke = KeyMapping.keystroke(for: event) else { return event }
        switch matcher.feed(stroke, at: event.timestamp) {
        case .none:
            return event
        case .partial:
            return nil
        case .matched(let id):
            return run(id) ? nil : event
        }
    }
}

/// System-wide hotkey for `toggle-window` (Quake-style show/hide), via Carbon's
/// `RegisterEventHotKey`, which doesn't need Accessibility permission.
@MainActor
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    var action: (() -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handlerInstalled = false

    /// Tabby's `registerGlobalHotkey`: the first stroke of every `toggle-window` binding. A
    /// `hacks.globalHotkey` other than null or false turns it off, as in Tabby's `app.ts`.
    static func strokes(from config: ConfigStore) -> [Keystroke] {
        if let hack = config.value("hacks.globalHotkey"), hack != .null, hack != false { return [] }
        return HotkeyBinding.bindings(from: config.value("hotkeys.toggle-window")).compactMap(\.strokes.first)
    }

    func register(_ strokes: [Keystroke]) {
        unregister()
        for (index, stroke) in strokes.enumerated() {
            guard let (code, mods) = KeyMapping.carbonHotKey(for: stroke) else { continue }
            installHandlerIfNeeded()
            let id = EventHotKeyID(signature: OSType(0x5442_4D43), id: UInt32(index + 1)) // 'TBMC'
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotkey.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
#endif
