import AppKit
import UserNotifications

/// Mac notifications for watched pages. Helm's browser extension hands each
/// alert to the native host (NativeHost), which passes it to this running app;
/// clicking the notification opens the page.
@MainActor
final class WatchAlerts: NSObject, UNUserNotificationCenterDelegate {
    private let engine: SyncEngine

    init(engine: SyncEngine) {
        self.engine = engine
    }

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        DistributedNotificationCenter.default().addObserver(forName: NativeHost.alert, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            MainActor.assumeIsolated { self?.show(info) }
        }
    }

    private func show(_ info: [String: String]) {
        guard engine.settings.notifyWatches, let title = info["title"], !title.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = info["message"] ?? ""
        content.sound = .default
        content.userInfo = ["url": info["url"] ?? ""]
        content.threadIdentifier = "watch:\(title)"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let link = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: link), !link.isEmpty {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }

    // Show banners even while Helm's own window is in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
