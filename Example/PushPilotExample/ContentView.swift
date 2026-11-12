import PushPilot
import PushPilotNotificationService
import SwiftUI
import UserNotifications

/// Buttons for each SDK call, so the integration can be tried by hand.
struct ContentView: View {
    @State private var userId = "user-1"
    @State private var status = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Permission") {
                    // The app asks for permission and registers for the token itself; PushPilot only reports the result.
                    Button("Allow notifications") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                            DispatchQueue.main.async {
                                if granted { UIApplication.shared.registerForRemoteNotifications() }
                                status = granted ? "Notifications allowed" : "Notifications not allowed"
                            }
                        }
                    }
                }
                Section("User") {
                    TextField("External user id", text: $userId)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    Button("Set user id") {
                        PushPilot.setExternalUserId(userId)
                        status = "User id set"
                    }
                    Button("Log out") {
                        PushPilot.logout()
                        status = "Logged out"
                    }
                }
                Section("Topics") {
                    Button("Set topics: news, offers") {
                        PushPilot.setTopics(["news", "offers"])
                        status = "Topics set"
                    }
                }
                Section("Privacy") {
                    Button("Forget this device", role: .destructive) {
                        PushPilot.forget()
                        status = "Device forgotten"
                    }
                }
                Section("Debug") {
                    // Checks buttons and taps on the simulator without a server.
                    Button("Show a test push in 3 seconds") {
                        scheduleTestPush()
                        status = "Test push scheduled; lock the screen or wait for the banner"
                    }
                }
                if !status.isEmpty {
                    Text(status).foregroundColor(.secondary)
                }
            }
            .navigationTitle("PushPilot Example")
        }
    }
}

/// Shows a local notification carrying a canned payload v2 push (two buttons, non-Latin text). A local
/// notification skips the Notification Service Extension, so the app runs the same helper on it first to
/// register the buttons. Needs notification permission.
private func scheduleTestPush() {
    let content = UNMutableNotificationContent()
    content.title = "नमस्ते 👋"
    content.body = "طلبك في الطريق — your order has shipped"
    content.sound = .default
    content.userInfo = [
        "source": "pushpilot",
        "notification_id": UUID().uuidString.lowercased(),
        "url": "https://example.com/orders/42",
        "buttons": [
            ["id": "track", "label": "ट्रैक करें", "url": "https://example.com/orders/42/track"],
            ["id": "later", "label": "لاحقاً"],
        ],
        "data": ["order_id": "42"],
    ]
    let helper = PushPilotServiceExtension()
    let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
    _ = helper.didReceive(request) { enriched in
        guard let ready = enriched.mutableCopy() as? UNMutableNotificationContent else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: ready, trigger: trigger))
        withExtendedLifetime(helper) {}
    }
}
