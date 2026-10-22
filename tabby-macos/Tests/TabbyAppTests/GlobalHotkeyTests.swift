#if canImport(AppKit)
import XCTest
@testable import TabbyCore
@testable import TabbyApp

/// The system-wide `toggle-window` shortcut, as Tabby's `registerGlobalHotkey`
/// (`tabby-electron/src/index.ts`) and `app/lib/app.ts` set it up.
@MainActor
final class GlobalHotkeyTests: XCTestCase {
    func makeStore() throws -> ConfigStore {
        ConfigStore(defaults: try ConfigStore.bundledDefaults())
    }

    /// Tabby registers the first stroke of every binding. Only the first binding was used, so a
    /// shortcut added next to the default ⌃Space, which macOS keeps for switching input
    /// sources, never worked.
    func testEveryBindingIsRegistered() throws {
        let store = try makeStore()
        store.set("hotkeys.toggle-window", ["Ctrl-Space", "Ctrl-⌥-J"])
        XCTAssertEqual(GlobalHotkey.strokes(from: store), [Keystroke("Ctrl-Space")!, Keystroke("Ctrl-⌥-J")!])
    }

    /// `hacks.globalHotkey` is not a binding: set to anything but null or false, Tabby leaves
    /// the shortcut to the desktop and registers nothing.
    func testGlobalHotkeyHackTurnsRegistrationOff() throws {
        let store = try makeStore()
        store.set("hacks.globalHotkey", true)
        XCTAssertEqual(GlobalHotkey.strokes(from: store), [])
        store.set("hacks.globalHotkey", false)
        XCTAssertEqual(GlobalHotkey.strokes(from: store), [Keystroke("Ctrl-Space")!])
    }
}
#endif
