import Foundation

/// Human-readable names for hotkey ids, used by the Hotkeys settings page and the command
/// palette. Ids and wording follow Tabby's `HotkeyProvider`s.
public enum HotkeyCatalog {
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: String
        /// The catalog key: Tabby's wording, with `{number}` for the numbered entries.
        public let key: String
        public let group: String
        public var number: Int?
        /// Values for the key's other placeholders (`{profile}`, `{type}`, `{name}`, `{tab}`).
        public var arguments: [String: String] = [:]

        public init(id: String, key: String, group: String, number: Int? = nil, arguments: [String: String] = [:]) {
            self.id = id
            self.key = key
            self.group = group
            self.number = number
            self.arguments = arguments
        }

        /// English, as in Tabby's hotkey list (config and tests use it).
        public var name: String {
            if let number { return key.replacingOccurrences(of: "{number}", with: String(number)) }
            return arguments.reduce(key) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
        }
        /// The name in the current language.
        public var title: String {
            if let number { return L(key, ["number": number]) }
            return arguments.isEmpty ? L(key) : L(key, arguments)
        }
        public var groupTitle: String { L(group) }
    }

    /// Tabby's provided hotkeys: "New tab: {profile}" for each profile, a profile selector for
    /// each type and each group, and each settings page.
    public static func dynamicEntries(profiles: [Profile], types: [(id: String, name: String)], groups: [ProfileGroup],
                                      settingsPages: [(id: String, title: String)]) -> [Entry] {
        profiles.map { Entry(id: $0.hotkeyId, key: Lkey("New tab: {profile}"), group: Lkey("Profiles"), arguments: ["profile": $0.name]) }
            + types.map { Entry(id: "profile-selectors.\($0.id)", key: Lkey("Show {type} profile selector"), group: Lkey("Profiles"),
                                arguments: ["type": $0.name]) }
            + groups.map { Entry(id: "group-selectors.\($0.id)", key: Lkey("Show profile selector for group {name}"), group: Lkey("Profiles"),
                                 arguments: ["name": $0.name]) }
            + settingsPages.map { Entry(id: "settings-tab.\($0.id)", key: Lkey("Open settings tab: {tab}"), group: Lkey("Application"),
                                        arguments: ["tab": $0.title]) }
    }

    public static let entries: [Entry] = {
        var e: [Entry] = []
        func add(_ id: String, _ key: String, _ group: String, number: Int? = nil) { e.append(Entry(id: id, key: key, group: group, number: number)) }
        // Application
        add("new-window", Lkey("New window"), Lkey("Application"))
        add("toggle-window", Lkey("Show/hide window (global)"), Lkey("Application"))
        add("settings", Lkey("Open Settings"), Lkey("Application"))
        add("sync-now", Lkey("Sync account now"), Lkey("Application"))
        add("command-selector", Lkey("Show command selector"), Lkey("Application"))
        add("profile-selector", Lkey("Show profile selector"), Lkey("Application"))
        add("switch-profile", Lkey("Switch profile in the active pane"), Lkey("Application"))
        add("toggle-fullscreen", Lkey("Toggle fullscreen mode"), Lkey("Application"))
        // Tabs
        add("new-tab", Lkey("New tab"), Lkey("Tabs"))
        add("close-tab", Lkey("Close tab"), Lkey("Tabs"))
        add("reopen-tab", Lkey("Reopen last tab"), Lkey("Tabs"))
        add("rename-tab", Lkey("Rename tab"), Lkey("Tabs"))
        add("duplicate-tab", Lkey("Duplicate tab"), Lkey("Tabs"))
        add("pin-tab", Lkey("Pin tab"), Lkey("Tabs"))
        add("restart-tab", Lkey("Restart tab"), Lkey("Tabs"))
        add("reconnect-tab", Lkey("Reconnect tab"), Lkey("Tabs"))
        add("disconnect-tab", Lkey("Disconnect tab"), Lkey("Tabs"))
        add("toggle-last-tab", Lkey("Toggle last tab"), Lkey("Tabs"))
        add("next-tab", Lkey("Next tab"), Lkey("Tabs"))
        add("previous-tab", Lkey("Previous tab"), Lkey("Tabs"))
        add("next-mru-tab", Lkey("Next tab (MRU order)"), Lkey("Tabs"))
        add("previous-mru-tab", Lkey("Previous tab (MRU order)"), Lkey("Tabs"))
        add("move-tab-left", Lkey("Move tab to the left"), Lkey("Tabs"))
        add("move-tab-right", Lkey("Move tab to the right"), Lkey("Tabs"))
        add("explode-tab", Lkey("Turn panes into tabs"), Lkey("Tabs"))
        add("combine-tabs", Lkey("Combine tabs into the current tab"), Lkey("Tabs"))
        for i in 1...20 { add("tab-\(i)", Lkey("Tab {number}"), Lkey("Tabs"), number: i) }
        // Panes
        add("split-right", Lkey("Split to the right"), Lkey("Panes"))
        add("split-bottom", Lkey("Split to the bottom"), Lkey("Panes"))
        add("split-left", Lkey("Split to the left"), Lkey("Panes"))
        add("split-top", Lkey("Split to the top"), Lkey("Panes"))
        add("close-pane", Lkey("Close focused pane"), Lkey("Panes"))
        add("pane-maximize", Lkey("Maximize the active pane"), Lkey("Panes"))
        add("pane-nav-up", Lkey("Focus the pane above"), Lkey("Panes"))
        add("pane-nav-down", Lkey("Focus the pane below"), Lkey("Panes"))
        add("pane-nav-left", Lkey("Focus the pane on the left"), Lkey("Panes"))
        add("pane-nav-right", Lkey("Focus the pane on the right"), Lkey("Panes"))
        add("pane-nav-previous", Lkey("Focus previous pane"), Lkey("Panes"))
        add("pane-nav-next", Lkey("Focus next pane"), Lkey("Panes"))
        for i in 1...9 { add("pane-nav-\(i)", Lkey("Focus pane {number}"), Lkey("Panes"), number: i) }
        add("pane-increase-vertical", Lkey("Increase vertical pane size"), Lkey("Panes"))
        add("pane-decrease-vertical", Lkey("Decrease vertical pane size"), Lkey("Panes"))
        add("pane-increase-horizontal", Lkey("Increase horizontal pane size"), Lkey("Panes"))
        add("pane-decrease-horizontal", Lkey("Decrease horizontal pane size"), Lkey("Panes"))
        add("pane-focus-all", Lkey("Focus all panes at once (broadcast)"), Lkey("Panes"))
        add("rearrange-panes", Lkey("Show pane labels (for rearranging)"), Lkey("Panes"))
        // Terminal
        add("copy", Lkey("Copy to clipboard"), Lkey("Terminal"))
        add("paste", Lkey("Paste from clipboard"), Lkey("Terminal"))
        add("select-all", Lkey("Select all"), Lkey("Terminal"))
        add("clear", Lkey("Clear terminal"), Lkey("Terminal"))
        add("search", Lkey("Search"), Lkey("Terminal"))
        add("zoom-in", Lkey("Zoom in"), Lkey("Terminal"))
        add("zoom-out", Lkey("Zoom out"), Lkey("Terminal"))
        add("reset-zoom", Lkey("Reset zoom"), Lkey("Terminal"))
        add("ctrl-c", Lkey("Intelligent Ctrl-C (copy/abort)"), Lkey("Terminal"))
        add("copy-current-path", Lkey("Copy current path"), Lkey("Terminal"))
        add("home", Lkey("Beginning of the line"), Lkey("Terminal"))
        add("end", Lkey("End of the line"), Lkey("Terminal"))
        add("previous-word", Lkey("Jump to previous word"), Lkey("Terminal"))
        add("next-word", Lkey("Jump to next word"), Lkey("Terminal"))
        add("delete-previous-word", Lkey("Delete previous word"), Lkey("Terminal"))
        add("delete-line", Lkey("Delete entire line"), Lkey("Terminal"))
        add("delete-next-word", Lkey("Delete next word"), Lkey("Terminal"))
        add("insert-new-line", Lkey("Insert new line"), Lkey("Terminal"))
        add("scroll-to-top", Lkey("Scroll to top"), Lkey("Terminal"))
        add("scroll-page-up", Lkey("Scroll up one page"), Lkey("Terminal"))
        add("scroll-up", Lkey("Scroll up one line"), Lkey("Terminal"))
        add("scroll-down", Lkey("Scroll down one line"), Lkey("Terminal"))
        add("scroll-page-down", Lkey("Scroll down one page"), Lkey("Terminal"))
        add("scroll-to-bottom", Lkey("Scroll to bottom"), Lkey("Terminal"))
        add("focus-all-tabs", Lkey("Focus all tabs at once"), Lkey("Terminal"))
        add("switch-meta-option", Lkey("Toggle Option as Meta key"), Lkey("Terminal"))
        // SSH
        add("restart-ssh-session", Lkey("Restart current SSH session"), Lkey("SSH"))
        add("open-sftp", Lkey("Open SFTP panel"), Lkey("SSH"))
        // Serial and telnet
        add("serial", Lkey("Show Serial connections"), Lkey("Serial"))
        add("restart-serial-session", Lkey("Restart current serial session"), Lkey("Serial"))
        add("restart-telnet-session", Lkey("Restart current Telnet session"), Lkey("Telnet"))
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
