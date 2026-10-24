#if canImport(AppKit)
import AppKit
import TabbyCore
import TabbyTerminal
import TabbyCLIKit

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
        case "settings": model.openSettings()
        case "sync-now":
            let account = AppServices.shared.account
            if account.isSignedIn {
                Task { await account.syncNow() }
            } else {
                AccountSheets.present(.signIn, in: window)
            }
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
        case "restart-telnet-session", "restart-serial-session":
            // Tabby's per-type restart acts on its own kind of tab only.
            guard let pane, "restart-\(pane.profile.type)-session" == id else { return false }
            pane.restart()
        case "serial": showSerialSelector()
        case "disconnect-tab": pane?.disconnect()
        case "open-sftp":
            // Tabby's "Open SFTP panel" (library backend, connected).
            guard let pane, SFTPPanels.canOpen(pane) else { return false }
            SFTPPanels.shared.toggle(for: pane)
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
        case "focus-all-tabs":
            guard model.activePane != nil || model.broadcastAllTabs else { return false }
            model.broadcastAllTabs.toggle()
        case "rename-pane": if let pane { renamePaneAsking(pane) }
        case "toggle-pane-label":
            guard let pane, pane.customTitle?.isEmpty == false else { return false }
            pane.customTitleVisible.toggle()
            RecoveryCoordinator.shared.scheduleSave()
        case "rearrange-panes":
            // ★ From the palette or a key binding with a key: on until a drop or the same command.
            guard let t = model.activeTab, t.content == nil else { return false }
            t.isRearranging.toggle()

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
        case NotifyMenu.whenDone: pane.map { $0.setNotifyWhenDone(!$0.notifyWhenDone) }
        case NotifyMenu.onActivity: pane.map { $0.setNotifyOnActivity(!$0.notifyOnActivity) }
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
        case "export-buffer": exportBuffer()
        case "new-terminal":
            guard let pane else { return false }
            openNewTerminal(from: pane)
        case "save-as-profile":
            guard let pane else { return false }
            saveAsProfileAsking(pane)
        case "copy-current-path":
            guard let cwd = pane?.currentDirectory() else { return true }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cwd, forType: .string)
        case "switch-meta-option":
            let config = AppServices.shared.config
            config.set("terminal.altIsMeta", .bool(!config.bool("terminal.altIsMeta")))

        default:
            if id.hasPrefix("tab-"), let n = Int(id.dropFirst(4)) {
                // On the start page ⌘1–⌘3 open the recent profiles it lists.
                if model.tabs.isEmpty {
                    let recents = StartPageView.recentProfiles()
                    if recents.indices.contains(n - 1) { model.openTab(profile: recents[n - 1]) }
                } else {
                    model.select(index: n - 1)
                }
            } else if id.hasPrefix("pane-nav-"), let n = Int(id.dropFirst(9)) {
                model.navigatePane(index: n - 1)
            } else if id.hasPrefix(NewTabMenu.commandPrefix) {
                let wanted = String(id.dropFirst(NewTabMenu.commandPrefix.count))
                guard let pane, let profile = AppServices.shared.profiles.allProfiles(includeHidden: true).first(where: { $0.id == wanted })
                else { return false }
                openProfile(profile, from: pane)
            } else if id.hasPrefix("profile-selectors.") {
                showProfileSelector(type: String(id.dropFirst("profile-selectors.".count)))
            } else if id.hasPrefix("group-selectors.") {
                showProfileSelector(groupId: String(id.dropFirst("group-selectors.".count)))
            } else if id.hasPrefix("settings-tab.") {
                guard let section = SettingsSection(tabbyId: String(id.dropFirst("settings-tab.".count))) else { return false }
                model.openSettings(section: section)
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

    /// The profile selector; `type` or `groupId` narrow it (Tabby's `profile-selectors.<type>`
    /// and `group-selectors.<id>` hotkeys).
    func showProfileSelector(switchActivePane: Bool = false, type: String? = nil, groupId: String? = nil) {
        let registry = AppServices.shared.profiles
        let items = profileSelectorItems(type: type, groupId: groupId, switchActivePane: switchActivePane)
        SelectorPanel.present(over: window, placeholder: switchActivePane ? L("Switch profile") : L("Search profiles or user@host:port"),
                              items: items) { [weak self] query in
            registry.selectorEntries(query: query, type: type, groupId: groupId).compactMap { entry -> SelectorItem? in
                guard case let .quickConnect(providerId, q) = entry.kind,
                      let profile = registry.quickConnect(q, providerId: providerId) else { return nil }
                return ProfileSelectorRows.quickConnect(providerId: providerId, query: q) {
                    self?.open(profile, switchActivePane: switchActivePane)
                }
            }
        }
    }

    func profileSelectorItems(type: String? = nil, groupId: String? = nil, switchActivePane: Bool = false) -> [SelectorItem] {
        let registry = AppServices.shared.profiles
        var items: [SelectorItem] = []
        for (i, entry) in registry.selectorEntries(type: type, groupId: groupId).enumerated() {
            switch entry.kind {
            case .profile(let p):
                items.append(SelectorItem(id: "p\(i)", title: entry.title, group: entry.group, subtitle: entry.description,
                                          icon: ProfileIcons.symbol(for: p.icon ?? ProfileIcons.defaultIcon(forType: p.type)),
                                          color: p.color) { [weak self] in
                    self?.open(p, switchActivePane: switchActivePane)
                })
            case .manageProfiles:
                items.append(SelectorItem(id: "manage", title: entry.title, icon: "gearshape") { [weak self] in
                    self?.model.openSettings(section: .profiles)
                })
            case .clearRecent:
                items.append(SelectorItem(id: "clear", title: entry.title, group: entry.group, icon: "trash") {
                    registry.recents.clear()
                })
            case .quickConnect:
                break
            }
        }
        return items
    }

    func open(_ profile: Profile, switchActivePane: Bool) {
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
            items.append(SelectorItem(id: entry.id, title: entry.title, group: entry.groupTitle, shortcut: binding?.symbolicDescription) { [weak self] in
                _ = self?.runCommand(entry.id)
            })
        }
        SelectorPanel.present(over: window, placeholder: L("Type a command"), items: items)
    }

    // MARK: Tab actions

    func renameActiveTab() {
        guard let tab = model.activeTab else { return }
        Prompts.text(in: window, title: L("Rename tab"), value: tab.customTitle ?? tab.title, confirm: L("Rename")) { value, _ in
            guard let value else { return }
            tab.customTitle = value.isEmpty ? nil : value
            RecoveryCoordinator.shared.scheduleSave()
        }
    }

    /// Saves the active tab's layout as a `split-layout` profile (Tabby's "Save layout as profile").
    func saveLayoutAsProfile() {
        guard let tab = model.activeTab, let token = tab.recoveryToken() else { return }
        Prompts.text(in: window, title: L("Save layout as profile"), value: tab.title, confirm: L("Save")) { name, _ in
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

    // MARK: Panes

    func renamePaneAsking(_ pane: TerminalPane) {
        Prompts.text(in: window, title: L("Rename pane"), value: pane.customTitle ?? pane.title, confirm: L("Rename")) { [weak self] value, _ in
            guard let value else { return }
            self?.renamePane(pane, to: value)
        }
    }

    /// Tabby's `setCustomTitle`: an empty name clears it; a first name turns the label on.
    func renamePane(_ pane: TerminalPane, to name: String) {
        let had = pane.customTitle?.isEmpty == false
        pane.customTitle = name.isEmpty ? nil : name
        if !had && !name.isEmpty { pane.customTitleVisible = true }
        RecoveryCoordinator.shared.scheduleSave()
    }

    /// A modifier-only hotkey pressed or released (`rearrange-panes` while ⌃⇧ are held).
    func modifierHotkey(_ id: String, down: Bool) {
        guard id == "rearrange-panes", let tab = model.activeTab, tab.content == nil else { return }
        // A drag in progress keeps the labels until it drops.
        if !down && PaneDragLabel.isDragging { return }
        tab.isRearranging = down
    }

    // MARK: New terminal, new with profile, save as profile

    /// Tabby's "New terminal": a tab with this pane's profile when it is a local shell, else
    /// the default profile; it opens in this pane's folder unless the profile names one.
    func openNewTerminal(from pane: TerminalPane) {
        model.focus(paneID: pane.id)
        model.openTab(profile: pane.profile.type == "local" ? pane.profile : AppServices.shared.defaultProfile())
    }

    /// Tabby's "New with profile": in the profile's folder, else this local pane's; a folder
    /// that doesn't exist is dropped.
    func openProfile(_ profile: Profile, from pane: TerminalPane) {
        var cwd = LocalOptions(profile.options).cwd.flatMap { $0.isEmpty ? nil : $0 }
            ?? (pane.profile.type == "local" ? pane.currentDirectory() : nil)
        var isDirectory: ObjCBool = false
        if let path = cwd, !(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue) { cwd = nil }
        model.focus(paneID: pane.id)
        model.openTab(profile: profile, cwd: cwd)
    }

    func saveAsProfileAsking(_ pane: TerminalPane) {
        Prompts.text(in: window, title: L("Save as profile"), message: L("New profile name"), value: pane.profile.name,
                     confirm: L("Save")) { [weak self] name, _ in
            guard let name, !name.isEmpty else { return }
            self?.saveAsProfile(pane, name: name)
        }
    }

    /// Tabby's "Save as profile": the pane's profile with its current folder, as a new profile.
    @discardableResult
    func saveAsProfile(_ pane: TerminalPane, name: String) -> Profile? {
        let source = pane.profile
        var options = source.options
        if let cwd = pane.currentDirectory() ?? LocalOptions(source.options).cwd { options["cwd"] = .string(cwd) }
        let saved = AppServices.shared.profiles.save(Profile(
            type: source.type, name: name, group: source.group, options: options, icon: source.icon, color: source.color,
            disableDynamicTitle: source.disableDynamicTitle, behaviorOnSessionEnd: source.behaviorOnSessionEnd))
        toasts.show(ToastCenter.Toast(symbol: "checkmark.circle", tint: .success, title: L("Saved"), detail: ""))
        return saved
    }

    // MARK: Dropping files

    /// Tabby's path drop: the pane takes focus and gets each path quoted, as if typed.
    func dropFiles(_ urls: [URL], on pane: TerminalPane) {
        model.focus(paneID: pane.id)
        let bracketed = pane.settings.bracketedPaste && pane.engine?.isBracketedPasteMode == true
        for chunk in PathDrop.text(for: urls.map(\.path), bracketed: bracketed) { pane.send(text: chunk) }
    }

    // MARK: Links

    static let defaultOpenURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Hands a URL to its app (tests record it).
    static var openURL: (URL) -> Void = defaultOpenURL
    static let defaultRevealInFinder: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    /// Shows a file in Finder (tests record it).
    static var revealInFinder: (URL) -> Void = defaultRevealInFinder

    /// ★ A click never runs anything: programs, scripts and app bundles are shown in Finder.
    static func isProgram(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        if ["app", "command", "tool", "sh", "pkg", "mpkg", "terminal", "workflow", "scpt", "applescript", "jar"] // l10n-ignore: file extensions
            .contains(url.pathExtension.lowercased()) { return true }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return NSWorkspace.shared.isFilePackage(atPath: path) }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// A clicked link (Tabby's linkifier): web links and addresses go to their app, `ssh://`
    /// and `telnet://` open a quick-connect tab, and a path that exists on this Mac (resolved
    /// against a local pane's folder) opens in its default app.
    func openLink(_ link: String, from pane: TerminalPane) {
        let target = LinkTarget.resolve(link, cwd: pane.currentDirectory(), home: NSHomeDirectory(),
                                        local: pane.profile.type == "local") { FileManager.default.fileExists(atPath: $0) }
        switch target {
        case .web(let string)?:
            URL(string: string).map(Self.openURL)
        case .file(let path)?:
            if Self.isProgram(path) { Self.revealInFinder(URL(fileURLWithPath: path)) } else { Self.openURL(URL(fileURLWithPath: path)) }
        case .quickConnect(let string)?:
            guard let url = URL(string: string), case let .quickConnect(provider, query)? = TabbyURL.parse(url),
                  let profile = AppServices.shared.profiles.quickConnect(query, providerId: provider) else { return }
            model.openTab(profile: profile)
        case nil:
            break
        }
    }

    // MARK: Export to file

    typealias ExportChooser = (_ window: NSWindow?, _ suggestedName: String, _ directory: URL?, _ done: @escaping (URL?) -> Void) -> Void

    static let defaultChooseExportURL: ExportChooser = { window, name, directory, done in
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        if let directory { panel.directoryURL = directory }
        if let window {
            panel.beginSheetModal(for: window) { done($0 == .OK ? panel.url : nil) }
        } else {
            done(panel.runModal() == .OK ? panel.url : nil)
        }
    }
    /// Asks where to save (tests answer).
    static var chooseExportURL: ExportChooser = defaultChooseExportURL

    /// Tabby's "Export to file": the whole buffer, scrollback included, as text.
    /// ★ The selection is left alone, and a failed write says so.
    func exportBuffer() {
        guard let pane = model.activeTab?.focusedPane, pane.engine != nil else { return }
        let directory = pane.profile.type == "local" ? pane.currentDirectory().map { URL(fileURLWithPath: $0) } : nil
        Self.chooseExportURL(window, "terminal.txt", directory) { [weak self, weak pane] url in // l10n-ignore: a file name
            guard let self, let url, let engine = pane?.engine else { return }
            do {
                try Data(engine.bufferText().utf8).write(to: url)
                toasts.show(ToastCenter.Toast(symbol: "checkmark.circle", tint: .success, title: L("Saved to {path}", ["path": url.path]), detail: ""))
            } catch {
                toasts.show(ToastCenter.Toast(symbol: "exclamationmark.triangle", tint: .warning, title: L("Could not save the file"),
                                              detail: error.localizedDescription))
            }
        }
    }

    // MARK: Context menus

    /// The pane's context menu in the design's order: clipboard, Split submenu, broadcast and
    /// clear, then the session. Items show the command's first hotkey.
    func terminalContextMenu(for pane: TerminalPane) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ id: String, in target: NSMenu? = nil, checked: Bool = false, enabled: Bool = true) {
            let i = NSMenuItem(title: title, action: #selector(contextCommand(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = id
            i.state = checked ? .on : .off
            i.isEnabled = enabled
            if let stroke = HotkeyBinding.bindings(from: AppServices.shared.config.value("hotkeys.\(id)")).first,
               stroke.strokes.count == 1, let (key, mods) = KeyMapping.keyEquivalent(for: stroke.strokes[0]) {
                i.keyEquivalent = key
                i.keyEquivalentModifierMask = mods
            }
            (target ?? menu).addItem(i)
        }
        model.focus(paneID: pane.id)
        item(L("Copy"), "copy")
        item(L("Paste"), "paste")
        item(L("Copy Current Path"), "copy-current-path")
        if let tab = model.tabs.first(where: { $0.panes[pane.id] != nil }), tab.panes.count > 1 {
            let named = pane.customTitle?.isEmpty == false
            item(L("Rename pane"), "rename-pane")
            item(L("Show pane label"), "toggle-pane-label", checked: named && pane.customTitleVisible, enabled: named)
        }
        menu.addItem(.separator())
        let split = NSMenu()
        split.autoenablesItems = false
        item(L("Split Up"), "split-top", in: split)
        item(L("Split Right"), "split-right", in: split)
        item(L("Split Down"), "split-bottom", in: split)
        item(L("Split Left"), "split-left", in: split)
        let splitItem = NSMenuItem(title: L("Split"), action: nil, keyEquivalent: "")
        splitItem.submenu = split
        menu.addItem(splitItem)
        item(L("Broadcast Input to All Panes"), "pane-focus-all", checked: model.activeTab?.broadcastInput == true)
        item(L("Broadcast Input to All Tabs"), "focus-all-tabs", checked: model.broadcastAllTabs)
        item(L("Select All"), "select-all")
        item(L("Clear"), "clear")
        item(L("Export to file"), "export-buffer")
        let notify = NotifyMenu.items(for: pane)
        if !notify.isEmpty { menu.addItem(.separator()) }
        for entry in notify {
            if let command = entry.command {
                item(entry.title, command, checked: entry.checked)
            } else {
                let line = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                line.isEnabled = false
                menu.addItem(line)
            }
        }
        menu.addItem(.separator())
        item(L("Save as profile"), "save-as-profile")
        item(L("Switch Profile…"), "switch-profile")
        item(L("New terminal"), "new-terminal")
        let profiles = NSMenu()
        profiles.autoenablesItems = false
        for p in NewTabMenu.localProfiles() { item(p.name, NewTabMenu.commandPrefix + p.id, in: profiles) }
        let profilesItem = NSMenuItem(title: L("New with profile"), action: nil, keyEquivalent: "")
        profilesItem.submenu = profiles
        menu.addItem(profilesItem)
        if pane.connectionState != nil {
            if SFTPPanels.canOpen(pane) { item(L("Open SFTP Panel"), "open-sftp") }
            item(pane.isRunning ? L("Disconnect") : L("Reconnect"), pane.isRunning ? "disconnect-tab" : "reconnect-tab")
        } else {
            item(L("Restart"), "restart-tab")
        }
        item(L("Close Pane"), "close-pane")
        return menu
    }

    @objc func contextCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        runCommand(id)
    }
}
/// Rows of the profile selector (⌘E).
@MainActor
enum ProfileSelectorRows {
    /// Design C8b: "Quick connect · SSH connection" with the type's icon and the query.
    static func quickConnect(providerId: String, query: String, action: @escaping () -> Void) -> SelectorItem {
        SelectorItem(id: "qc-\(providerId)", title: L("Quick connect · {type}", ["type": ProfileTypes.title(providerId)]), group: L("Quick connect"),
                     subtitle: query, icon: ProfileIcons.symbol(for: ProfileIcons.defaultIcon(forType: providerId)), action: action)
    }
}
#endif
