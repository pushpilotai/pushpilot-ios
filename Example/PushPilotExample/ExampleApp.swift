import FirebaseCore
import FirebaseMessaging
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

/// Wires PushPilot to the app's own Firebase Messaging setup.
final class AppDelegate: NSObject, UIApplicationDelegate, MessagingDelegate, UNUserNotificationCenterDelegate {
    /// Starts PushPilot, then Firebase if this build has a GoogleService-Info.plist.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        PushPilot.initialize(sdkKey: pushPilotSdkKey)
        UNUserNotificationCenter.current().delegate = self
        // Without the plist the app still runs; it just never gets an FCM token.
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
            application.registerForRemoteNotifications()
        } else {
            print("GoogleService-Info.plist missing: Firebase is not configured, so no push token will arrive.")
        }
        return true
    }

    /// Hands the APNs token to Firebase, which exchanges it for an FCM token.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    /// Forwards every new Firebase Installation ID to PushPilot. Firebase registers at launch on its own
    /// because Info.plist sets FirebaseMessagingInstallationIdEnabled and auto-init is on.
    func messaging(_ messaging: Messaging, didReceiveRegistration installationId: String?) {
        PushPilot.setPushToken(installationId)
    }

    /// Shows pushes while the app is open and notes which ones PushPilot sent.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if PushPilot.handleMessage(notification.request.content.userInfo) {
            print("Received a PushPilot push")
        }
        completionHandler([.banner, .sound])
    }
}
