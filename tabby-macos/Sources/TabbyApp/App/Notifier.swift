#if canImport(AppKit)
import AppKit
import UserNotifications
import TabbyCore

/// System notifications (phase 5). Each carries the pane it is about, so opening one focuses
/// that pane and brings its window forward (Tabby's `Notification` click selects the tab);
/// they also show while TabbyMac is in front, as Tabby's do. Posting needs the app bundle:
/// `swift run` has none, and xctest's main bundle is a tool, where the notification center
/// raises. macOS may still refuse permission to an ad-hoc signed build; the callers show an
/// in-app toast as well.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    static let paneKey = "pane"

    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Delivers a notification; set by `start()` in the app bundle, by tests to record.
    var poster: ((_ title: String, _ body: String, _ pane: UUID) -> Void)?

    func start() {
        guard Self.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("TabbyMac: notifications unavailable: \(error.localizedDescription)") }
        }
        poster = { title, body, pane in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = [Notifier.paneKey: pane.uuidString]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func post(title: String, body: String, pane: UUID) {
        poster?(title, body, pane)
    }

    /// Focuses the pane in whichever window holds it; false when it is gone.
    @discardableResult
    func focus(paneID: UUID) -> Bool {
        for controller in WindowManager.shared.controllers where controller.model.tabs.contains(where: { $0.panes[paneID] != nil }) {
            controller.model.focus(paneID: paneID)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo[Notifier.paneKey] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            if let id { MainActor.assumeIsolated { _ = Notifier.shared.focus(paneID: id) } }
            completionHandler()
        }
    }
}
#endif
