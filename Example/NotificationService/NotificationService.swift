import PushPilotNotificationService
import UserNotifications

/// The example's Notification Service Extension: PushPilot attaches images to its own pushes.
final class NotificationService: UNNotificationServiceExtension {
    private let images = PushPilotImageAttacher()

    /// Lets PushPilot handle its pushes; any other push is delivered as it came.
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if images.didReceive(request, withContentHandler: contentHandler) { return }
        contentHandler(request.content)
    }

    /// Delivers the push without its image if the download is still running.
    override func serviceExtensionTimeWillExpire() {
        images.serviceExtensionTimeWillExpire()
    }
}
