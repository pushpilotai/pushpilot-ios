import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// The PushPilot SDK. Every method is safe to call from any thread and returns at once;
/// disk and network work happens on a private background queue.
public enum PushPilot {
    /// The server used when `initialize` gets no `baseUrl`.
    public static let defaultBaseUrl = URL(string: "https://pushpilot.ai")!
    /// The version reported to the server as `sdk_version`.
    public static let sdkVersion = "1.0.0"

    static let queue = DispatchQueue(label: "ai.pushpilot.sdk")
    /// Builds the engine; tests replace it to inject fakes.
    static var makeEngine: (String, URL) throws -> Engine = { key, url in
        try Engine(sdkKey: key, baseUrl: url, storage: DeviceStorage(), network: URLSessionNetwork(queue: queue),
                   clock: SystemClock(queue: queue), device: SystemDeviceInfo(queue: queue))
    }
    private static var config: (sdkKey: String, baseUrl: URL)?
    private static var engine: Engine?
    /// Calls made before the engine exists, run in order once it does.
    private static var waiting: [(Engine) -> Void] = []

    /// Starts the SDK with the app's public SDK key. Call once at launch; later calls are ignored.
    public static func initialize(sdkKey: String, baseUrl: URL = defaultBaseUrl) {
        queue.async {
            guard config == nil else { return }
            guard !sdkKey.isEmpty else { return log.error("initialize ignored: sdkKey is empty") }
            config = (sdkKey, baseUrl)
            #if canImport(UIKit)
            // didBecomeActive also fires when the permission alert closes, so a new permission is reported at once.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: nil) { _ in
                queue.async { start(); engine?.requestSync() }
            }
            #endif
            start()
        }
    }

    /// Passes the APNs device token from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
    /// as is; nil clears it. The app calls `registerForRemoteNotifications()` itself; the SDK never does.
    public static func setPushToken(_ deviceToken: Data?) { run { $0.setPushToken(deviceToken) } }

    /// Links this installation to the app's own user id, usually right after login.
    public static func setExternalUserId(_ id: String) { run { $0.setExternalUserId(id) } }

    /// Sets attributes declared for the app in the dashboard. Values: String, Bool, a number, Date, or nil to remove.
    public static func setAttributes(_ attributes: [String: Any?]) { run { $0.setAttributes(attributes) } }

    /// Replaces this installation's topics.
    public static func setTopics(_ topics: [String]) { run { $0.setTopics(topics) } }

    /// Clears the external user id; the installation stays registered and keeps receiving pushes.
    public static func logout() { run { $0.logout() } }

    /// Deletes this installation from PushPilot and clears local state. A new installation is registered
    /// after the next setter call or the next launch.
    public static func forget() { run { $0.forget() } }

    /// Returns whether a received push came from PushPilot. Makes no network call and needs no `initialize`.
    public static func handleMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["source"] as? String == "pushpilot"
    }

    /// Creates the engine once storage is readable and replays waiting calls; retries every 30 s if it is not.
    private static func start() {
        guard engine == nil, let config else { return }
        do {
            let created = try makeEngine(config.sdkKey, config.baseUrl)
            engine = created
            waiting.forEach { $0(created) }
            waiting = []
            created.requestSync()
        } catch {
            log.error("Storage unavailable, retrying in 30 s: \(error.localizedDescription, privacy: .public)")
            queue.asyncAfter(deadline: .now() + 30) { start() }
        }
    }

    /// Runs `work` on the SDK queue now, or after `initialize` if the engine does not exist yet.
    private static func run(_ work: @escaping (Engine) -> Void) {
        queue.async {
            if let engine { work(engine) } else { waiting.append(work) }
        }
    }
}
