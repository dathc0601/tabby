#if canImport(AppKit)
import AppKit
import TabbyCore

/// The menu bar. Items that map to Tabby hotkey ids show the configured shortcut; the
/// hotkey monitor runs them first, so menu equivalents only fire when it passes an event on
/// (e.g. while a text field has focus).
@MainActor
enum MainMenu {
    private static var commandItems: [(NSMenuItem, String)] = []

    static func install() {
        // TabbyMac has its own tabs: keep macOS from adding its window-tab items (Show Tab Bar,
        // Merge All Windows, …) to the View and Window menus.
        NSWindow.allowsAutomaticWindowTabbing = false
        commandItems = []
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About TabbyMac", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(command("Settings…", "settings"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide TabbyMac", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit TabbyMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        add(appMenu, title: "TabbyMac", to: main)

        let shell = NSMenu(title: "Shell")
        shell.addItem(command("New Tab", "new-tab"))
        shell.addItem(command("New Window", "new-window"))
        shell.addItem(command("Profiles & Connections…", "profile-selector"))
        shell.addItem(command("Command Palette…", "command-selector"))
        shell.addItem(.separator())
        shell.addItem(command("Split Right", "split-right"))
        shell.addItem(command("Split Down", "split-bottom"))
        shell.addItem(command("Split Left", "split-left"))
        shell.addItem(command("Split Up", "split-top"))
        shell.addItem(.separator())
        shell.addItem(command("Rename Tab…", "rename-tab"))
        shell.addItem(command("Duplicate Tab", "duplicate-tab"))
        shell.addItem(command("Reopen Closed Tab", "reopen-tab"))
        shell.addItem(command("Restart Session", "restart-tab"))
        shell.addItem(command("Disconnect", "disconnect-tab"))
        shell.addItem(command("Reconnect", "reconnect-tab"))
        shell.addItem(command("Save Layout as Profile…", "save-layout-as-profile"))
        shell.addItem(.separator())
        shell.addItem(command("Close Pane", "close-pane"))
        shell.addItem(command("Close Tab", "close-tab"))
        add(shell, title: "Shell", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(.separator())
        edit.addItem(command("Clear Buffer", "clear"))
        edit.addItem(command("Find…", "search"))
        edit.addItem(command("Copy Current Path", "copy-current-path"))
        add(edit, title: "Edit", to: main)

        let view = NSMenu(title: "View")
        view.addItem(command("Zoom In", "zoom-in"))
        view.addItem(command("Zoom Out", "zoom-out"))
        view.addItem(command("Actual Size", "reset-zoom"))
        view.addItem(.separator())
        view.addItem(command("Maximize Pane", "pane-maximize"))
        view.addItem(command("Broadcast Input to All Panes", "pane-focus-all"))
        view.addItem(.separator())
        view.addItem(fullScreenItem())
        add(view, title: "View", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(command("Next Tab", "next-tab"))
        window.addItem(command("Previous Tab", "previous-tab"))
        window.addItem(command("Move Tab Left", "move-tab-left"))
        window.addItem(command("Move Tab Right", "move-tab-right"))
        window.addItem(command("Next Pane", "pane-nav-next"))
        window.addItem(command("Previous Pane", "pane-nav-previous"))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
        refreshShortcuts()
    }

    private static func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }

    private static func command(_ title: String, _ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
        item.target = MenuTarget.shared
        item.representedObject = id
        commandItems.append((item, id))
        return item
    }

    /// "Enter Full Screen" with AppKit's own action, so AppKit neither adds a second one to the
    /// View menu nor misses retitling it "Exit Full Screen". Its shortcut still follows `hotkeys`.
    private static func fullScreenItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        commandItems.append((item, "toggle-fullscreen"))
        return item
    }

    /// Updates key equivalents from `hotkeys:` (first single-stroke binding of each command).
    static func refreshShortcuts() {
        let config = AppServices.shared.config
        for (item, id) in commandItems {
            let binding = HotkeyBinding.bindings(from: config.value("hotkeys.\(id)")).first { $0.strokes.count == 1 }
            if let stroke = binding?.strokes.first, let (key, mods) = KeyMapping.keyEquivalent(for: stroke) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mods
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }
}

@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()

    @objc func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if let key = NSApp.keyWindow, !(key is TerminalWindow), !["settings", "new-window", "new-tab", "profile-selector"].contains(id) {
            if id == "close-tab" || id == "close-pane" { key.performClose(nil) }
            return
        }
        switch id {
        case "settings": SettingsWindowController.show()
        case "new-window": WindowManager.shared.newWindow()
        default:
            if let controller = WindowManager.shared.activeController {
                controller.runCommand(id)
            } else if id == "new-tab" {
                WindowManager.shared.newWindow()
            }
        }
    }
}
#endif
