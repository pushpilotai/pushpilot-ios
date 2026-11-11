// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PushPilot",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "PushPilot", targets: ["PushPilot"]),
    ],
    targets: [
        .target(name: "PushPilot"),
        .testTarget(name: "PushPilotTests", dependencies: ["PushPilot"]),
    ]
)
