#if canImport(AppKit)
import AppKit
import QuartzCore
import UserNotifications
import TabbyCore
import TabbySSH
import TabbyAccount

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
        services.libSSHFactory.ui = LibSSHPromptPresenter.shared

        services.account.onSyncFinished = { report, error in
            MainActor.assumeIsolated { WindowManager.shared.syncFinished(report, error: error) }
        }
        MainMenu.install()
        let manager = HotkeyManager { id in
            if id == "settings" { WindowManager.shared.openSettings(); return true }
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
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
                if let error { NSLog("TabbyMac: notifications unavailable: \(error.localizedDescription)") }
            }
        }

        let controller = WindowManager.shared.newWindow(openDefaultTab: false)
        let restored = RecoveryCoordinator.shared.restore(into: controller)
        let autoOpen = services.config.value("terminal.autoOpen")?.boolValue ?? true
        if !restored && autoOpen {
            controller.model.openTab()
        }
        if WelcomePolicy.shouldShow(config: services.config, restoredTabs: restored) {
            controller.model.openWelcome()
        }
        RecoveryCoordinator.shared.start()
        DockController.shared.apply(followMouse: true)
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
        return Self.quitAlert(warnings: busy).runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Quit is the default button (design C10).
    static func quitAlert(warnings: [String]) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Quit TabbyMac?"
        alert.informativeText = warnings.joined(separator: "\n")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecoveryCoordinator.shared.saveForTermination()
        AppServices.shared.stop()
    }

    private func registerGlobalHotkey() {
        GlobalHotkey.shared.register(GlobalHotkey.strokes(from: AppServices.shared.config))
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

    private var lastSyncError: String?
    private var offeredKeyFiles: Set<String> = []

    /// Toasts for sync results in the active window, and the one-time question about new key
    /// files.
    func syncFinished(_ report: SyncReport?, error: Error?) {
        let account = AppServices.shared.account
        guard let controller = activeController else { return }
        if let error {
            let message = error.localizedDescription
            if message != lastSyncError {
                controller.toasts.show(ToastCenter.Toast(symbol: "exclamationmark.icloud", tint: .danger, title: "Sync failed", detail: message,
                                                         actionTitle: "Settings", action: { [weak self] in self?.openSettings(section: .account) }), for: 8)
            }
            lastSyncError = message
            return
        }
        lastSyncError = nil
        guard let report else { return }
        if report.applied && !account.isRestoring {
            controller.toasts.show(ToastCenter.Toast(symbol: "arrow.triangle.2.circlepath.icloud", tint: .accent,
                                                     title: "Synced", detail: "Changes from your other Macs are here."))
        }
        let fresh = report.pendingKeyFiles.filter { !offeredKeyFiles.contains($0.id) }
        if !fresh.isEmpty, controller.window?.attachedSheet == nil {
            offeredKeyFiles.formUnion(fresh.map(\.id))
            AccountSheets.presentKeyFiles(report.pendingKeyFiles, in: controller.window)
        }
    }

    /// Opens Settings as a tab of the active window (a new window when there is none).
    func openSettings(section: SettingsSection? = nil) {
        let controller = activeController ?? newWindow(openDefaultTab: false)
        controller.model.openSettings(section: section)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quake-style show/hide (`toggle-window`).
    func toggleAllWindows() {
        if NSApp.isActive && NSApp.windows.contains(where: { $0.isVisible && $0.windowController is MainWindowController }) {
            DockController.shared.slide(in: false) { NSApp.hide(nil) }
        } else {
            NSApp.unhide(nil)
            NSApp.activate(ignoringOtherApps: true)
            if controllers.isEmpty { newWindow() }
            DockController.shared.apply(followMouse: true)
            activeController?.window?.makeKeyAndOrderFront(nil)
            DockController.shared.slide(in: true)
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

    /// Set by the final save on quit.
    var isTerminating = false

    /// The save on quit, which is final: AppKit then closes every window "for termination",
    /// and each close would save what is left, so the window that closes last (an empty one)
    /// would overwrite every other window's tabs.
    func saveForTermination() {
        saveNow()
        isTerminating = true
    }

    /// Buffer snapshots serialise whole scrollbacks, so the debounced saves after small
    /// changes skip them; the 30-second timer and quitting include them.
    func saveNow(includeBuffers: Bool = true) {
        pending?.cancel()
        pending = nil
        guard !isTerminating else { return }
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

    /// Tabby's `setAlwaysOnTop(dockAlwaysOnTop)` while docked.
    var level: NSWindow.Level {
        let config = AppServices.shared.config
        guard config.string("appearance.dock") ?? "off" != "off" else { return .normal }
        return config.value("appearance.dockAlwaysOnTop")?.boolValue ?? true ? .floating : .normal
    }

    /// Tabby's display choice: `appearance.dockScreen` when it names a connected display
    /// (Electron's display id is the CGDirectDisplayID, AppKit's `NSScreenNumber`), otherwise
    /// the display under `point`.
    static func screen(for dockScreen: ConfigValue?, near point: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        if let id = dockScreen?.intValue, let match = screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == id
        }) {
            return match
        }
        return screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    /// Docks the first window. `followMouse` picks the display under the mouse, as Tabby does
    /// at launch and when the window is shown; for setting changes the window stays on its
    /// display (Settings is a separate window here and may sit on another one).
    func apply(followMouse: Bool = false) {
        let config = AppServices.shared.config
        let side = config.string("appearance.dock") ?? "off"
        guard let controller = WindowManager.shared.controllers.first, let window = controller.window else { return }
        window.level = level
        guard side != "off" else {
            window.collectionBehavior = [.fullScreenPrimary]
            return
        }
        let point = followMouse ? NSEvent.mouseLocation : CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let screen = Self.screen(for: config.value("appearance.dockScreen"), near: point) else { return }
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

    /// The design's slide: a docked window comes in from its screen edge and leaves the same
    /// way. Without docking (or with animations off) it just calls `completion`.
    func slide(in show: Bool, completion: @escaping () -> Void = {}) {
        let config = AppServices.shared.config
        let side = config.string("appearance.dock") ?? "off"
        guard side != "off", config.value("accessibility.animations")?.boolValue ?? true,
              let window = WindowManager.shared.controllers.first?.window else { return completion() }
        let docked = window.frame
        var away = docked
        switch side {
        case "top": away.origin.y += docked.height
        case "bottom": away.origin.y -= docked.height
        case "left": away.origin.x -= docked.width
        default: away.origin.x += docked.width
        }
        if show { window.setFrame(away, display: false) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            window.animator().setFrame(show ? docked : away, display: true)
        }, completionHandler: {
            MainActor.assumeIsolated {
                completion()
                if !show { window.setFrame(docked, display: false) }
            }
        })
    }
}
#endif
