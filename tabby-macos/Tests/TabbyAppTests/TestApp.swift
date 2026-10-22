#if canImport(AppKit)
import AppKit
@testable import TabbyCore
@testable import TabbyApp

/// Starts the app services once per test run, with a scratch config directory so tests never
/// touch the user's TabbyMac config.
@MainActor
enum TestApp {
    private static var booted = false

    static func boot() {
        guard !booted else { return }
        booted = true
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tabbymac-smoke-\(UUID().uuidString.prefix(6))").path
        setenv("TABBYMAC_CONFIG_DIRECTORY", dir, 1)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        AppServices.shared.start()
    }

    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// A local profile that runs `script` with `/bin/sh -c`.
    static func profile(_ name: String, _ script: String) -> Profile {
        Profile(id: "local:\(name)", type: "local", name: name,
                options: LocalOptions(command: "/bin/sh", args: ["-c", script]).configValue)
    }

    /// Closes every tab of a test window (ending its processes) and hides it.
    static func dispose(_ controller: MainWindowController) {
        for tab in controller.model.tabs {
            for pane in tab.orderedPanes { pane.close() }
        }
        controller.window?.orderOut(nil)
    }
}
#endif
