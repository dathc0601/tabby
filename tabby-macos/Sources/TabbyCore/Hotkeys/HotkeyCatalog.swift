import Foundation

/// Human-readable names for hotkey ids, used by the Hotkeys settings page and the command
/// palette. Ids and wording follow Tabby's `HotkeyProvider`s.
public enum HotkeyCatalog {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let group: String
    }

    public static let entries: [Entry] = {
        var e: [Entry] = []
        func add(_ id: String, _ name: String, _ group: String) { e.append(Entry(id: id, name: name, group: group)) }
        // Application
        add("new-window", "New window", "Application")
        add("toggle-window", "Show/hide window (global)", "Application")
        add("settings", "Open Settings", "Application")
        add("sync-now", "Sync account now", "Application")
        add("command-selector", "Show command selector", "Application")
        add("profile-selector", "Show profile selector", "Application")
        add("switch-profile", "Switch profile in the active pane", "Application")
        add("toggle-fullscreen", "Toggle fullscreen mode", "Application")
        // Tabs
        add("new-tab", "New tab", "Tabs")
        add("close-tab", "Close tab", "Tabs")
        add("reopen-tab", "Reopen last tab", "Tabs")
        add("rename-tab", "Rename tab", "Tabs")
        add("duplicate-tab", "Duplicate tab", "Tabs")
        add("pin-tab", "Pin tab", "Tabs")
        add("restart-tab", "Restart tab", "Tabs")
        add("reconnect-tab", "Reconnect tab", "Tabs")
        add("disconnect-tab", "Disconnect tab", "Tabs")
        add("toggle-last-tab", "Toggle last tab", "Tabs")
        add("next-tab", "Next tab", "Tabs")
        add("previous-tab", "Previous tab", "Tabs")
        add("next-mru-tab", "Next tab (MRU order)", "Tabs")
        add("previous-mru-tab", "Previous tab (MRU order)", "Tabs")
        add("move-tab-left", "Move tab to the left", "Tabs")
        add("move-tab-right", "Move tab to the right", "Tabs")
        add("explode-tab", "Turn panes into tabs", "Tabs")
        add("combine-tabs", "Combine tabs into the current tab", "Tabs")
        for i in 1...20 { add("tab-\(i)", "Tab \(i)", "Tabs") }
        // Panes
        add("split-right", "Split to the right", "Panes")
        add("split-bottom", "Split to the bottom", "Panes")
        add("split-left", "Split to the left", "Panes")
        add("split-top", "Split to the top", "Panes")
        add("close-pane", "Close focused pane", "Panes")
        add("pane-maximize", "Maximize the active pane", "Panes")
        add("pane-nav-up", "Focus the pane above", "Panes")
        add("pane-nav-down", "Focus the pane below", "Panes")
        add("pane-nav-left", "Focus the pane on the left", "Panes")
        add("pane-nav-right", "Focus the pane on the right", "Panes")
        add("pane-nav-previous", "Focus previous pane", "Panes")
        add("pane-nav-next", "Focus next pane", "Panes")
        for i in 1...9 { add("pane-nav-\(i)", "Focus pane \(i)", "Panes") }
        add("pane-increase-vertical", "Increase vertical pane size", "Panes")
        add("pane-decrease-vertical", "Decrease vertical pane size", "Panes")
        add("pane-increase-horizontal", "Increase horizontal pane size", "Panes")
        add("pane-decrease-horizontal", "Decrease horizontal pane size", "Panes")
        add("pane-focus-all", "Focus all panes at once (broadcast)", "Panes")
        add("rearrange-panes", "Show pane labels (for rearranging)", "Panes")
        // Terminal
        add("copy", "Copy to clipboard", "Terminal")
        add("paste", "Paste from clipboard", "Terminal")
        add("select-all", "Select all", "Terminal")
        add("clear", "Clear terminal", "Terminal")
        add("search", "Search", "Terminal")
        add("zoom-in", "Zoom in", "Terminal")
        add("zoom-out", "Zoom out", "Terminal")
        add("reset-zoom", "Reset zoom", "Terminal")
        add("ctrl-c", "Intelligent Ctrl-C (copy/abort)", "Terminal")
        add("copy-current-path", "Copy current path", "Terminal")
        add("home", "Beginning of the line", "Terminal")
        add("end", "End of the line", "Terminal")
        add("previous-word", "Jump to previous word", "Terminal")
        add("next-word", "Jump to next word", "Terminal")
        add("delete-previous-word", "Delete previous word", "Terminal")
        add("delete-line", "Delete entire line", "Terminal")
        add("delete-next-word", "Delete next word", "Terminal")
        add("insert-new-line", "Insert new line", "Terminal")
        add("scroll-to-top", "Scroll to top", "Terminal")
        add("scroll-page-up", "Scroll up one page", "Terminal")
        add("scroll-up", "Scroll up one line", "Terminal")
        add("scroll-down", "Scroll down one line", "Terminal")
        add("scroll-page-down", "Scroll down one page", "Terminal")
        add("scroll-to-bottom", "Scroll to bottom", "Terminal")
        add("focus-all-tabs", "Focus all tabs at once", "Terminal")
        add("switch-meta-option", "Toggle Option as Meta key", "Terminal")
        // SSH
        add("restart-ssh-session", "Restart current SSH session", "SSH")
        add("open-sftp", "Open SFTP panel", "SSH")
        // Telnet
        add("restart-telnet-session", "Restart current Telnet session", "Telnet")
        return e
    }()

    public static let byId: [String: Entry] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    public static func name(for id: String) -> String {
        byId[id]?.name ?? id
    }

    /// Entries whose bindings clash with `binding`: the same keys, or one chord starting with
    /// the other (the shorter one would fire first).
    public static func conflicts(with binding: HotkeyBinding, excluding id: String, config: ConfigStore) -> [Entry] {
        func clash(_ a: [Keystroke], _ b: [Keystroke]) -> Bool {
            let n = min(a.count, b.count)
            return n > 0 && Array(a.prefix(n)) == Array(b.prefix(n))
        }
        return entries.filter { entry in
            entry.id != id && HotkeyBinding.bindings(from: config.value("hotkeys.\(entry.id)")).contains { clash($0.strokes, binding.strokes) }
        }
    }
}
