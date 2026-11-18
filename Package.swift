// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PushPilot",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "PushPilot", targets: ["PushPilot"]),
        // For the app's Notification Service Extension; independent of the app-only PushPilot target.
        .library(name: "PushPilotNotificationService", targets: ["PushPilotNotificationService"]),
        // For the app's Widget Extension: the live activity attributes, layout renderer and default widget.
        .library(name: "PushPilotLive", targets: ["PushPilotLive"]),
    ],
    targets: [
        .target(name: "PushPilot", dependencies: ["PushPilotLive"], resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "PushPilotNotificationService", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .target(name: "PushPilotLive"),
        .testTarget(name: "PushPilotTests", dependencies: ["PushPilot", "PushPilotNotificationService", "PushPilotLive"],
                    resources: [.copy("Resources/designs")]),
    ]
)
