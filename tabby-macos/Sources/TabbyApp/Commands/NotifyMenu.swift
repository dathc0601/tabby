#if canImport(AppKit)
import Foundation
import TabbyCore
import TabbyTerminal

/// The tab and pane menus' notify items, as Tabby's `TaskCompletionContextMenu` lists them:
/// "Current process: name" (a disabled line) and "Notify when done" while a foreground process
/// runs, then "Notify on activity". The commands act on the active tab's focused pane.
struct NotifyMenuItem: Equatable, Identifiable {
    let title: String
    /// `nil` for the disabled "Current process" line.
    let command: String?
    let checked: Bool
    var id: String { command ?? "current-process" }
}

enum NotifyMenu {
    static let whenDone = "notify-when-done"
    static let onActivity = "notify-on-activity"

    static func items(for pane: TerminalPane?) -> [NotifyMenuItem] {
        guard let pane, pane.isRunning else { return [] }
        var items: [NotifyMenuItem] = []
        if let name = pane.activeProcessName {
            items.append(NotifyMenuItem(title: L("Current process: {name}", ["name": name]), command: nil, checked: false))
            items.append(NotifyMenuItem(title: L("Notify when done"), command: whenDone, checked: pane.notifyWhenDone))
        } else if pane.notifyWhenDone {
            items.append(NotifyMenuItem(title: L("Notify when done"), command: whenDone, checked: true))
        }
        items.append(NotifyMenuItem(title: L("Notify on activity"), command: onActivity, checked: pane.notifyOnActivity))
        return items
    }
}
#endif
