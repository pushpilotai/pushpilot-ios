import PushPilot
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
                    // The app asks for permission itself; PushPilot only reports the result.
                    Button("Allow notifications") {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                            DispatchQueue.main.async { status = granted ? "Notifications allowed" : "Notifications not allowed" }
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
                if !status.isEmpty {
                    Text(status).foregroundColor(.secondary)
                }
            }
            .navigationTitle("PushPilot Example")
        }
    }
}
