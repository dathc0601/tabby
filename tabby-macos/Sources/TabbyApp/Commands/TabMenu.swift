#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbyTerminal

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, image: NSImage? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        self.image = image
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}

/// The tab header's menu (right-click and the "…" button), Tabby's tab-header context menu.
/// Built each time it opens, so it shows the tab as it is then.
@MainActor
enum TabMenu {
    static func build(for tab: TabModel, actions: TabBarActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, checked: Bool = false, to target: NSMenu? = nil, _ handler: @escaping () -> Void) {
            (target ?? menu).addItem(ClosureMenuItem(title, checked: checked, handler: handler))
        }
        func command(_ title: String, _ id: String, checked: Bool = false, to target: NSMenu? = nil) {
            add(title, checked: checked, to: target) { actions.command(id, tab) }
        }
        add(L("Close Tab")) { actions.close(tab) }
        command(L("Close Other Tabs"), "close-other-tabs")
        command(L("Close Tabs to the Left"), "close-tabs-left")
        command(L("Close Tabs to the Right"), "close-tabs-right")
        menu.addItem(.separator())
        if tab.content == nil {
            command(L("Rename Tab…"), "rename-tab")
            command(L("Duplicate Tab"), "duplicate-tab")
            command(L("Broadcast Input to All Tabs"), "focus-all-tabs", checked: actions.isBroadcastingToAllTabs())
            let notify = NotifyMenu.items(for: tab.focusedPane)
            if !notify.isEmpty { menu.addItem(.separator()) }
            for entry in notify {
                if let id = entry.command {
                    command(entry.title, id, checked: entry.checked)
                } else {
                    let line = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                    line.isEnabled = false
                    menu.addItem(line)
                }
            }
        }
        command(tab.isPinned ? L("Unpin Tab") : L("Pin Tab"), "pin-tab")
        let colours = NSMenu()
        colours.autoenablesItems = false
        add(L("None"), checked: tab.color == nil, to: colours) { actions.setColor(tab, nil) }
        colours.addItem(.separator())
        for c in TabColors.current() {
            colours.addItem(ClosureMenuItem(c.name, image: TabColors.swatch(c.hex, checked: tab.color?.lowercased() == c.hex)) {
                actions.setColor(tab, c.hex)
            })
        }
        submenu(L("Colour"), colours, in: menu)
        if tab.content == nil {
            menu.addItem(.separator())
            let split = NSMenu()
            split.autoenablesItems = false
            command(L("Split Up"), "split-top", to: split)
            command(L("Split Right"), "split-right", to: split)
            command(L("Split Down"), "split-bottom", to: split)
            command(L("Split Left"), "split-left", to: split)
            submenu(L("Split"), split, in: menu)
            command(L("Save Layout as Profile…"), "save-layout-as-profile")
            command(L("Export to file"), "export-buffer")
            command(L("Switch Profile…"), "switch-profile")
        }
        return menu
    }

    static func submenu(_ title: String, _ submenu: NSMenu, in menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}

/// A transparent layer over a tab header that answers right-clicks (and ⌃-clicks) with a menu
/// built at that moment. Every other mouse event goes through to the SwiftUI header.
struct ContextMenuArea: NSViewRepresentable {
    let tabID: UUID
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> ContextMenuView {
        let view = ContextMenuView()
        view.tabID = tabID
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: ContextMenuView, context: Context) {
        view.tabID = tabID
        view.makeMenu = makeMenu
    }
}

/// A button area that drops a menu built at that moment below itself (the tab's "…").
struct MenuButtonArea: NSViewRepresentable {
    let makeMenu: () -> NSMenu

    func makeNSView(context: Context) -> MenuButtonView {
        let view = MenuButtonView()
        view.makeMenu = makeMenu
        return view
    }

    func updateNSView(_ view: MenuButtonView, context: Context) { view.makeMenu = makeMenu }
}

final class MenuButtonView: NSView {
    var makeMenu: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : -4), in: self)
    }
}

final class ContextMenuView: NSView {
    var tabID: UUID?
    var makeMenu: (() -> NSMenu)?

    private static func isMenuClick(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.isMenuClick(NSApp.currentEvent) ? super.hitTest(point) : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return super.mouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
#endif
