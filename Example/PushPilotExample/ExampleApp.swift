import PushPilot
import SwiftUI
import UserNotifications

/// Replace with the public SDK key from the PushPilot dashboard (Apps page).
let pushPilotSdkKey = "pp_sdk_REPLACE_ME"

@main
struct ExampleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

/// Starts PushPilot and hands it the APNs device token. The app, not the SDK, registers for pushes.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Starts PushPilot and, if the user already allowed notifications, registers for the device token.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushPilot.initialize(sdkKey: pushPilotSdkKey)
        // Optional: route PushPilot links yourself. Without a handler the system opens them.
        PushPilot.setLinkHandler { url in
            print("PushPilot link: \(url)")
            UIApplication.shared.open(url)
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Registering at each launch keeps the token current; ContentView registers after the first grant.
            if [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
                DispatchQueue.main.async { application.registerForRemoteNotifications() }
            }
        }
        return true
    }

    /// Forwards the APNs device token to PushPilot as is.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushPilot.setPushToken(deviceToken)
    }

    /// Registration fails without the Push Notifications capability or a matching provisioning profile.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    /// Shows pushes while the app is open and notes which ones PushPilot sent.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if PushPilot.handleMessage(notification.request.content.userInfo) {
            print("Received a PushPilot push")
        }
        completionHandler([.banner, .sound])
    }

    /// Forwards taps to PushPilot, which records the click and opens the link; other pushes are yours.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if PushPilot.handleNotificationResponse(response) {
            print("PushPilot tap: \(response.actionIdentifier), data: \(userInfo["data"] as? [String: String] ?? [:])")
        }
        completionHandler()
    }
}
