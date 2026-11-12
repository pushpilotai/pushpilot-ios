import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

/// The PushPilot SDK. Every method is safe to call from any thread and returns at once;
/// disk and network work happens on a private background queue.
public enum PushPilot {
    /// The server used when `initialize` gets no `baseUrl`.
    public static let defaultBaseUrl = URL(string: "https://pushpilot.ai")!
    /// The version reported to the server as `sdk_version`.
    public static let sdkVersion = "2.0.0"

    static let queue = DispatchQueue(label: "ai.pushpilot.sdk")
    /// Builds the engine; tests replace it to inject fakes.
    static var makeEngine: (String, URL) throws -> Engine = { key, url in
        try Engine(sdkKey: key, baseUrl: url, storage: DeviceStorage(), network: URLSessionNetwork(queue: queue),
                   clock: SystemClock(queue: queue), device: SystemDeviceInfo(queue: queue))
    }
    /// Where the configuration from the last `initialize` is saved; tests replace it.
    static var configStorage: Storage = DeviceStorage()
    private static var config: SavedConfig?
    /// The app called `initialize` in this process; a start from the saved configuration does not count.
    private static var initialized = false
    private static var observingActive = false
    private static var engine: Engine?
    /// Calls made before the engine exists, run in order once it does.
    private static var waiting: [(Engine) -> Void] = []
    /// The app's own link handler; nil lets the system open links. Used only on the SDK queue.
    private static var linkHandler: ((URL) -> Void)?
    /// Opens a link when the app set no handler; tests replace it.
    static var systemOpen: (URL) -> Void = { url in
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Starts the SDK with the app's public SDK key. Call once at launch; later calls are ignored.
    ///
    /// The key and `baseUrl` are saved on the device. In a later process where the app has not called
    /// `initialize` yet, such as one launched by a tap on a push, the first SDK call starts the SDK from
    /// them, so a click or a token is sent instead of waiting in memory. When `initialize` then runs, its
    /// values replace the saved ones.
    public static func initialize(sdkKey: String, baseUrl: URL = defaultBaseUrl) {
        queue.async {
            guard !initialized else { return }
            guard !sdkKey.isEmpty else { return log.error("initialize ignored: sdkKey is empty") }
            initialized = true
            let given = SavedConfig(sdkKey: sdkKey, baseUrl: baseUrl)
            if (try? configStorage.readConfig()) != given {
                do { try configStorage.writeConfig(given) } catch {
                    log.error("Could not save the configuration: \(error.localizedDescription, privacy: .public)")
                }
            }
            configure(given)
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
    /// after the next setter call or the next launch. The saved SDK key and server are kept: they are the
    /// app's settings, not data about the user.
    public static func forget() { run { $0.forget() } }

    /// Returns whether a received push came from PushPilot. Makes no network call and needs no `initialize`.
    public static func handleMessage(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["source"] as? String == "pushpilot"
    }

    /// Forward `userNotificationCenter(_:didReceive:withCompletionHandler:)` here. For a PushPilot push it
    /// records the click (with the button id when a button was tapped) and opens the button's `url` or the
    /// push's `url`. Returns false for any other push so your code can handle it. Your own values are in
    /// `response.notification.request.content.userInfo["data"]` as `[String: String]`.
    public static func handleNotificationResponse(_ response: UNNotificationResponse) -> Bool {
        handleTap(userInfo: response.notification.request.content.userInfo, action: response.actionIdentifier)
    }

    /// Sends the links of tapped PushPilot pushes to `handler`, on the main thread, instead of letting the
    /// system open them; nil restores the default.
    public static func setLinkHandler(_ handler: ((URL) -> Void)?) {
        queue.async { linkHandler = handler }
    }

    /// Records the click and opens its link; false when the push is not from PushPilot.
    static func handleTap(userInfo: [AnyHashable: Any], action: String) -> Bool {
        guard handleMessage(userInfo) else { return false }
        guard let tap = Tap(userInfo: userInfo, action: action) else { return true }
        if let id = tap.notificationId { run { $0.trackClick(notificationId: id, buttonId: tap.buttonId) } }
        if let url = tap.url {
            queue.async {
                let open = linkHandler ?? systemOpen
                DispatchQueue.main.async { open(url) }
            }
        }
        return true
    }

    /// Uses `given` from now on: starts the engine, or points an engine started from the saved values at it.
    private static func configure(_ given: SavedConfig) {
        config = given
        if let engine {
            engine.sdkKey = given.sdkKey
            engine.baseUrl = given.baseUrl
        }
        #if canImport(UIKit)
        if !observingActive {
            observingActive = true
            // didBecomeActive also fires when the permission alert closes, so a new permission is reported at once.
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: nil) { _ in
                queue.async { start(); engine?.requestSync() }
            }
        }
        #endif
        start()
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

    /// Runs `work` on the SDK queue now, or once the engine exists. Before `initialize` it first tries
    /// to start the SDK from the saved configuration.
    private static func run(_ work: @escaping (Engine) -> Void) {
        queue.async { runNow(work) }
    }

    /// `run` for code already on the SDK queue.
    private static func runNow(_ work: @escaping (Engine) -> Void) {
        if config == nil, let saved = try? configStorage.readConfig() { configure(saved) }
        if let engine { work(engine) } else { waiting.append(work) }
    }

    /// Forgets everything held in memory, as in a new process; for tests.
    static func resetForTesting() {
        queue.sync {
            config = nil; initialized = false; engine = nil; waiting = []; linkHandler = nil
        }
    }
}

/// What a tap on a PushPilot push means: which notification, which button, and which link to open.
struct Tap: Equatable {
    let notificationId: String?
    let buttonId: String?
    let url: URL?

    /// Reads a tap from the push and the action iOS reports; nil for a dismissal, which is not an event.
    init?(userInfo: [AnyHashable: Any], action: String) {
        guard action != UNNotificationDismissActionIdentifier else { return nil }
        notificationId = Self.text(userInfo["notification_id"])
        if action == UNNotificationDefaultActionIdentifier {
            buttonId = nil
            url = Self.text(userInfo["url"]).flatMap(URL.init(string:))
        } else {
            // Button ids are the category's action identifiers (see PushPilotServiceExtension).
            buttonId = action
            let button = (userInfo["buttons"] as? [[String: Any]])?.first { $0["id"] as? String == action }
            url = Self.text(button?["url"]).flatMap(URL.init(string:))
        }
    }

    /// A non-empty string, or nil.
    private static func text(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
