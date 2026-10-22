#if canImport(AppKit)
import AppKit
import UserNotifications
import TabbyCore
import TabbySSH

/// Entry point used by the Xcode app target (`App/main.swift`) and by `swift run TabbyMacDev`.
public enum TabbyAppMain {
    @MainActor
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkeys: HotkeyManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let services = AppServices.shared
        services.start()
        services.sshFactory.promptHandler = SSHPromptPresenter.shared

        MainMenu.install()
        let manager = HotkeyManager { id in
            if id == "settings" { SettingsWindowController.show(); return true }
            if id == "new-window" { WindowManager.shared.newWindow(); return true }
            guard let controller = WindowManager.shared.activeController else { return false }
            return controller.runCommand(id)
        }
        manager.reload(from: services.config)
        manager.start()
        hotkeys = manager
        HotkeyCapture.manager = manager

        GlobalHotkey.shared.action = { WindowManager.shared.toggleAllWindows() }
        registerGlobalHotkey()
        services.config.observe { [weak self] in
            MainActor.assumeIsolated {
                self?.hotkeys?.reload(from: services.config)
                self?.registerGlobalHotkey()
                MainMenu.refreshShortcuts()
                DockController.shared.apply()
            }
        }

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }

        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        let restored = RecoveryCoordinator.shared.restore(into: controller)
        let autoOpen = services.config.value("terminal.autoOpen")?.boolValue ?? true
        if !restored && autoOpen {
            controller.model.openTab()
        }
        RecoveryCoordinator.shared.start()
        DockController.shared.apply()
        NSApp.activate(ignoringOtherApps: true)

        if let error = services.loadError {
            Prompts.message(in: controller.window, title: "Couldn't read config.yaml", message: "\(error)\n\nDefaults are in use; your file was not modified.")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { WindowManager.shared.newWindow() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let sshWarn = AppServices.shared.config.bool("ssh.warnOnClose")
        let busy = WindowManager.shared.controllers.flatMap { $0.model.tabs.flatMap(\.orderedPanes) }
            .compactMap { $0.closeWarning(sshWarnOnClose: sshWarn) }
        guard !busy.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit TabbyMac?"
        alert.informativeText = busy.joined(separator: "\n")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecoveryCoordinator.shared.saveNow()
        AppServices.shared.stop()
    }

    private func registerGlobalHotkey() {
        let config = AppServices.shared.config
        let raw = config.value("hacks.globalHotkey")?.stringValue
        let binding = raw.flatMap(HotkeyBinding.init) ?? HotkeyBinding.bindings(from: config.value("hotkeys.toggle-window")).first
        GlobalHotkey.shared.register(binding?.strokes.first)
    }
}

/// Tracks terminal windows.
@MainActor
final class WindowManager {
    static let shared = WindowManager()
    private(set) var controllers: [MainWindowController] = []
    weak var lastActive: MainWindowController?

    var activeController: MainWindowController? {
        if let key = NSApp.keyWindow?.windowController as? MainWindowController { return key }
        if let main = NSApp.mainWindow?.windowController as? MainWindowController { return main }
        return lastActive ?? controllers.first
    }

    @discardableResult
    func newWindow(openDefaultTab: Bool = true) -> MainWindowController {
        let controller = MainWindowController()
        controller.onClose = { [weak self] c in
            self?.controllers.removeAll { $0 === c }
        }
        controllers.append(controller)
        if let previous = activeController?.window, previous !== controller.window {
            controller.window?.setFrameTopLeftPoint(CGPoint(x: previous.frame.minX + 24, y: previous.frame.maxY - 24))
        }
        controller.showWindow(nil)
        lastActive = controller
        if openDefaultTab { controller.model.openTab() }
        return controller
    }

    /// Quake-style show/hide (`toggle-window`).
    func toggleAllWindows() {
        if NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && $0.windowController is MainWindowController }) {
            NSApp.hide(nil)
        } else {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            if controllers.isEmpty { newWindow() }
            DockController.shared.apply()
            activeController?.window?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Saves and restores open tabs (Tabby's `TabRecoveryService`): debounced after changes,
/// every 30 seconds, and at quit.
@MainActor
final class RecoveryCoordinator {
    static let shared = RecoveryCoordinator()
    private var pending: DispatchWorkItem?
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { RecoveryCoordinator.shared.saveNow(includeBuffers: true) }
        }
    }

    func scheduleSave() {
        pending?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { RecoveryCoordinator.shared.saveNow(includeBuffers: false) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Buffer snapshots serialise whole scrollbacks, so the debounced saves after small
    /// changes skip them; the 30-second timer and quitting include them.
    func saveNow(includeBuffers: Bool = true) {
        pending?.cancel()
        pending = nil
        let services = AppServices.shared
        guard services.config.value("recoverTabs")?.boolValue ?? true else {
            try? services.recovery.save([])
            return
        }
        let tokens = WindowManager.shared.controllers.flatMap { $0.model.recoveryTokens(includeBuffers: includeBuffers) }
        try? services.recovery.save(tokens)
    }

    /// Restores saved tabs into a window. Returns true when anything was restored.
    func restore(into controller: MainWindowController) -> Bool {
        let services = AppServices.shared
        guard services.config.value("recoverTabs")?.boolValue ?? true else { return false }
        let tokens = services.recovery.load()
        for t in tokens { controller.model.restore(t) }
        if let first = controller.model.tabs.first { controller.model.select(first.id) }
        return !controller.model.tabs.isEmpty
    }
}

/// Docked ("Quake console") window mode: `appearance.dock` = top/bottom/left/right.
/// Port of `tabby-electron/src/services/docking.service.ts`.
@MainActor
final class DockController {
    static let shared = DockController()

    /// Tabby's `setAlwaysOnTop(dockAlwaysOnTop)`, applied every time so turning it off while
    /// docked lowers the window again.
    var level: NSWindow.Level {
        let config = AppServices.shared.config
        guard config.string("appearance.dock") ?? "off" != "off" else { return .normal }
        return config.value("appearance.dockAlwaysOnTop")?.boolValue ?? true ? .floating : .normal
    }

    func apply() {
        let config = AppServices.shared.config
        let side = config.string("appearance.dock") ?? "off"
        guard let controller = WindowManager.shared.controllers.first, let window = controller.window else { return }
        window.level = level
        guard side != "off" else {
            window.collectionBehavior = [.fullScreenPrimary]
            return
        }
        guard let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let fill = CGFloat(config.double("appearance.dockFill") ?? 0.5)
        let space = CGFloat(config.double("appearance.dockSpace") ?? 1)
        var frame = area
        switch side {
        case "top", "bottom":
            frame.size.height = area.height * fill
            frame.size.width = area.width * space
            frame.origin.x = area.minX + (area.width - frame.width) / 2
            frame.origin.y = side == "top" ? area.maxY - frame.height : area.minY
        default:
            frame.size.width = area.width * fill
            frame.size.height = area.height * space
            frame.origin.y = area.minY + (area.height - frame.height) / 2
            frame.origin.x = side == "left" ? area.minX : area.maxX - frame.width
        }
        window.setFrame(frame, display: true, animate: false)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
#endif
