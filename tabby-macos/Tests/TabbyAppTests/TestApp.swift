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
        // Never the real server or a signed-in session from the user's Keychain.
        setenv("TABBYMAC_SYNC_URL", "memory:", 1)
        setenv("TABBYMAC_KEYCHAIN", "memory", 1)
        setenv("TABBYMAC_SYNC_HOME", dir + "/home", 1)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        AppServices.shared.start()
    }

    static func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Runs the main loop until `condition` holds or `timeout` passes, and returns it. A fixed
    /// pause can be too short for a shell to start on a slow CI runner.
    @discardableResult
    static func pump(until condition: () -> Bool, timeout: Double = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { pump(0.05) }
        return condition()
    }

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
