#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbyTerminal

/// Hotkey / menu / palette command dispatch for a window. The ids are Tabby's hotkey ids
/// (`tabby-core/src/hotkeys.ts`, `tabby-terminal/src/hotkeys.ts`), so `hotkeys:` in an
/// imported config.yaml works unchanged.
extension MainWindowController {
    /// Runs a command. Returns false when it doesn't apply (the key then reaches the terminal).
    @discardableResult
    func runCommand(_ id: String) -> Bool {
        let pane = model.activePane
        let engineView = pane.flatMap { paneView(for: $0) }
        switch id {
        // Application
        case "new-window": WindowManager.shared.newWindow()
        case "settings": SettingsWindowController.show()
        case "profile-selector": showProfileSelector()
        case "switch-profile": showProfileSelector(switchActivePane: true)
        case "command-selector": showCommandPalette()
        case "toggle-fullscreen": window?.toggleFullScreen(nil)
        case "toggle-window": WindowManager.shared.toggleAllWindows()

        // Tabs
        case "new-tab": model.openTab()
        case "close-tab":
            guard let tab = model.activeTab else { window?.performClose(nil); return true }
            requestCloseTab(tab)
        case "reopen-tab": model.reopenLastTab()
        case "rename-tab": renameActiveTab()
        case "duplicate-tab": if let t = model.activeTab { model.duplicateTab(t.id) }
        case "pin-tab": if let t = model.activeTab { model.togglePinned(t.id) }
        case "restart-tab", "reconnect-tab", "restart-ssh-session": pane?.restart()
        case "disconnect-tab": pane?.disconnect()
        case "toggle-last-tab": model.toggleLastTab()
        case "next-tab": model.selectRelative(1)
        case "previous-tab": model.selectRelative(-1)
        case "next-mru-tab": model.selectMRU(1)
        case "previous-mru-tab": model.selectMRU(-1)
        case "move-tab-left": model.moveActiveTab(by: -1)
        case "move-tab-right": model.moveActiveTab(by: 1)
        case "explode-tab": model.explodeActiveTab()
        case "combine-tabs": model.combineTabs()
        case "close-other-tabs": if let t = model.activeTab { requestCloseTabs(model.tabs(otherThan: t.id)) }
        case "close-tabs-left": if let t = model.activeTab { requestCloseTabs(model.tabs(toThe: .left, of: t.id)) }
        case "close-tabs-right": if let t = model.activeTab { requestCloseTabs(model.tabs(toThe: .right, of: t.id)) }
        case "save-layout-as-profile": saveLayoutAsProfile()

        // Panes
        case "split-right": model.split(.right)
        case "split-bottom": model.split(.bottom)
        case "split-left": model.split(.left)
        case "split-top": model.split(.top)
        case "close-pane": if let pane { requestClosePane(pane) }
        case "pane-maximize": model.toggleMaximize()
        case "pane-nav-up": model.navigatePane(.top)
        case "pane-nav-down": model.navigatePane(.bottom)
        case "pane-nav-left": model.navigatePane(.left)
        case "pane-nav-right": model.navigatePane(.right)
        case "pane-nav-previous": model.navigatePaneLinear(-1)
        case "pane-nav-next": model.navigatePaneLinear(1)
        case "pane-increase-vertical": model.resizePane(.vertical, grow: true)
        case "pane-decrease-vertical": model.resizePane(.vertical, grow: false)
        case "pane-increase-horizontal": model.resizePane(.horizontal, grow: true)
        case "pane-decrease-horizontal": model.resizePane(.horizontal, grow: false)
        case "pane-focus-all": if let t = model.activeTab { t.broadcastInput.toggle() }

        // Terminal
        case "copy":
            guard let engine = engineView?.engine, engine.copySelection() else { return false }
            engine.clearSelection()
        case "ctrl-c":
            if let engine = engineView?.engine, engine.copySelection() {
                engine.clearSelection()
            } else {
                send("\u{03}")
            }
        case "paste": engineView?.engine.pasteFromClipboard()
        case "select-all": engineView?.engine.selectAll()
        case "clear": engineView?.engine.clearBuffer()
        case "search": engineView?.toggleSearch()
        case "zoom-in": pane?.zoom(by: 1)
        case "zoom-out": pane?.zoom(by: -1)
        case "reset-zoom": pane?.resetZoom()
        case "home": send(pane?.engine?.isAlternateScreen == true ? "\u{1b}OH" : "\u{01}")
        case "end": send(pane?.engine?.isAlternateScreen == true ? "\u{1b}OF" : "\u{05}")
        case "previous-word": send("\u{1b}b")
        case "next-word": send("\u{1b}f")
        case "delete-previous-word": send("\u{17}")
        case "delete-line": send("\u{1b}w")
        case "delete-next-word": send("\u{1b}d")
        case "insert-new-line": send("\u{1b}\r")
        case "scroll-to-top": pane?.engine?.scroll(.top)
        case "scroll-page-up": pane?.engine?.scroll(.pageUp)
        case "scroll-up": pane?.engine?.scroll(.lineUp)
        case "scroll-down": pane?.engine?.scroll(.lineDown)
        case "scroll-page-down": pane?.engine?.scroll(.pageDown)
        case "scroll-to-bottom": pane?.engine?.scroll(.bottom)
        case "copy-current-path":
            guard let cwd = pane?.currentDirectory() else { return true }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cwd, forType: .string)
        case "switch-meta-option":
            let config = AppServices.shared.config
            config.set("terminal.altIsMeta", .bool(!config.bool("terminal.altIsMeta")))

        default:
            if id.hasPrefix("tab-"), let n = Int(id.dropFirst(4)) {
                model.select(index: n - 1)
            } else if id.hasPrefix("pane-nav-"), let n = Int(id.dropFirst(9)) {
                model.navigatePane(index: n - 1)
            } else if id.hasPrefix("profile.") {
                let wanted = String(id.dropFirst("profile.".count))
                guard let p = AppServices.shared.profiles.allProfiles(includeHidden: true)
                    .first(where: { $0.hotkeyId == id || $0.id == wanted }) else { return false }
                model.openTab(profile: p)
            } else {
                return false
            }
        }
        return true
    }

    /// Sends text to the active pane, or to every pane of the tab when broadcasting.
    func send(_ text: String) {
        guard let tab = model.activeTab else { return }
        if tab.broadcastInput {
            for p in tab.orderedPanes { p.send(text: text) }
        } else {
            tab.focusedPane?.send(text: text)
        }
    }

    // MARK: Selectors

    func showProfileSelector(switchActivePane: Bool = false) {
        let services = AppServices.shared
        let registry = services.profiles
        var items: [SelectorItem] = []
        for (i, entry) in registry.selectorEntries().enumerated() {
            switch entry.kind {
            case .profile(let p):
                items.append(SelectorItem(id: "p\(i)", title: entry.title, group: entry.group, subtitle: entry.description,
                                          icon: ProfileIcons.symbol(for: p.icon ?? (p.type == "ssh" ? "network" : "terminal")),
                                          color: p.color) { [weak self] in
                    self?.open(p, switchActivePane: switchActivePane)
                })
            case .manageProfiles:
                items.append(SelectorItem(id: "manage", title: entry.title, icon: "gearshape") {
                    SettingsWindowController.show(section: .profiles)
                })
            case .clearRecent:
                items.append(SelectorItem(id: "clear", title: entry.title, group: entry.group, icon: "trash") {
                    registry.recents.clear()
                })
            case .quickConnect:
                break
            }
        }
        SelectorPanel.present(over: window, placeholder: switchActivePane ? "Switch profile" : "Search profiles or user@host:port",
                              items: items) { [weak self] query in
            registry.selectorEntries(query: query).compactMap { entry -> SelectorItem? in
                guard case let .quickConnect(providerId, q) = entry.kind,
                      let profile = registry.quickConnect(q, providerId: providerId) else { return nil }
                return SelectorItem(id: "qc-\(providerId)", title: q, group: "Quick connect", subtitle: entry.description, icon: "bolt") {
                    self?.open(profile, switchActivePane: switchActivePane)
                }
            }
        }
    }

    private func open(_ profile: Profile, switchActivePane: Bool) {
        if switchActivePane {
            model.switchActivePane(to: profile)
        } else if profile.type == "split-layout", let token = profile.options["recoveryToken"].flatMap(RecoveryToken.init) {
            model.restore(token, includeBuffer: false)
        } else {
            model.openTab(profile: profile)
        }
    }

    func showCommandPalette() {
        let config = AppServices.shared.config
        var items: [SelectorItem] = []
        for entry in HotkeyCatalog.entries where entry.id != "command-selector" {
            let binding = HotkeyBinding.bindings(from: config.value("hotkeys.\(entry.id)")).first
            items.append(SelectorItem(id: entry.id, title: entry.name, group: entry.group, shortcut: binding?.symbolicDescription) { [weak self] in
                _ = self?.runCommand(entry.id)
            })
        }
        SelectorPanel.present(over: window, placeholder: "Type a command", items: items)
    }

    // MARK: Tab actions

    func renameActiveTab() {
        guard let tab = model.activeTab else { return }
        Prompts.text(in: window, title: "Rename tab", value: tab.customTitle ?? tab.title, confirm: "Rename") { value, _ in
            guard let value else { return }
            tab.customTitle = value.isEmpty ? nil : value
            RecoveryCoordinator.shared.scheduleSave()
        }
    }

    /// Saves the active tab's layout as a `split-layout` profile (Tabby's "Save layout as profile").
    func saveLayoutAsProfile() {
        guard let tab = model.activeTab, let token = tab.recoveryToken() else { return }
        Prompts.text(in: window, title: "Save layout as profile", value: tab.title, confirm: "Save") { name, _ in
            guard let name, !name.isEmpty else { return }
            var stripped = token
            if case let .split(o, r, c, p, t, col) = token {
                func strip(_ t: RecoveryToken) -> RecoveryToken {
                    switch t {
                    case .pane(var p): p.savedState = nil; return .pane(p)
                    case let .split(o, r, c, p, t, col): return .split(orientation: o, ratios: r, children: c.map(strip), pinned: p, customTitle: t, color: col)
                    }
                }
                stripped = .split(orientation: o, ratios: r, children: c.map(strip), pinned: p, customTitle: t, color: col)
            }
            let profile = Profile(type: "split-layout", name: name, options: ["recoveryToken": stripped.configValue], icon: "rectangle.split.2x1")
            AppServices.shared.profiles.save(profile)
        }
    }

    // MARK: Context menus

    func terminalContextMenu(for pane: TerminalPane) -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ id: String) {
            let i = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = id
            menu.addItem(i)
        }
        model.focus(paneID: pane.id)
        item("Copy", "copy")
        item("Paste", "paste")
        item("Select All", "select-all")
        item("Clear", "clear")
        menu.addItem(.separator())
        item("Split Right", "split-right")
        item("Split Down", "split-bottom")
        item("Split Left", "split-left")
        item("Split Up", "split-top")
        menu.addItem(.separator())
        item("Copy Current Path", "copy-current-path")
        item("Switch Profile…", "switch-profile")
        item(pane.isRunning ? "Restart" : "Reconnect", "restart-tab")
        item("Close Pane", "close-pane")
        return menu
    }

    @objc func contextCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runCommand(id)
    }
}
#endif
