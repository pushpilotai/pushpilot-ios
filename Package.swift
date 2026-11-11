// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PushPilot",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "PushPilot", targets: ["PushPilot"]),
        // For the app's Notification Service Extension; independent of the app-only PushPilot target.
        .library(name: "PushPilotNotificationService", targets: ["PushPilotNotificationService"]),
    ],
    targets: [
        .target(name: "PushPilot", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "PushPilotNotificationService", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "PushPilotTests", dependencies: ["PushPilot", "PushPilotNotificationService"]),
    ]
)
