#if canImport(UIKit) && canImport(WebKit)
import UIKit

/// Runs in-app messages on the main thread: fetches on foreground, keeps the cache, picks and shows a message,
/// and holds the marked views for coach marks (IN-APP-SDK.md sections 1 to 3 and 6).
@MainActor
final class InAppController {
    static let shared = InAppController()
    /// Fetches happen at most this often (chosen during the build).
    static let fetchInterval: TimeInterval = 60

    private let store = InAppStore.device
    /// The stub until the iOS SDK has a hinge API (IN-APP-SDK.md section 9).
    private let postureSource: InAppPostureSource = FlatPostureSource()
    private lazy var cache = store.readCache()
    private var started = false
    /// No foreground has been seen since the process started or the app went to the background.
    private var inBackground = true
    private var lastFetch: Date?
    private var refreshing = false
    private var overlay: InAppOverlay?
    /// Marked views by name, held weakly.
    private let marks = NSMapTable<NSString, UIView>.strongToWeakObjects()

    /// Watches the app's foregrounds; called once the SDK is configured. A start while the app is already
    /// in the foreground counts as one.
    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in InAppController.shared.inBackground = true }
        }
        // didBecomeActive also follows an alert or Control Center; only the first after a background counts.
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in InAppController.shared.foreground() }
        }
        if UIApplication.shared.applicationState == .active { foreground() }
    }

    /// A foreground: shows the first eligible `app_open` message from the cache, then refreshes the cache.
    private func foreground() {
        guard inBackground else { return }
        inBackground = false
        _ = show(.appOpen)
        refresh()
    }

    // MARK: Fetch and cache

    /// Starts a fetch unless one ran in the last minute or is still running.
    private func refresh() {
        guard !refreshing, lastFetch.map({ Date().timeIntervalSince($0) >= Self.fetchInterval }) ?? true else { return }
        refreshing = true
        PushPilot.run { engine in
            // The server knows an installation only after its first accepted register or sync.
            let synced = engine.state.lastSent?["installation_id"] == .string(engine.installationId)
            let caller = synced ? (sdkKey: engine.sdkKey, baseUrl: engine.baseUrl, installationId: engine.installationId) : nil
            Task { @MainActor in await InAppController.shared.fetch(caller) }
        }
    }

    /// Fetches the list, applies it, and caches every page not cached yet. Failed pages wait for the next fetch.
    private func fetch(_ caller: (sdkKey: String, baseUrl: URL, installationId: String)?) async {
        defer { refreshing = false }
        guard let caller else { return }
        lastFetch = Date()
        guard let list = await store.fetchList(baseUrl: caller.baseUrl, sdkKey: caller.sdkKey,
                                               installationId: caller.installationId) else { return }
        InAppStore.apply(list, to: &cache).forEach(store.deletePage)
        store.writeCache(cache)
        let slow = InAppPage.isSlowPhone()
        for message in list.messages where cache.pages[message.id] == nil {
            guard let page = await store.cache(message, slow: slow) else { continue }
            // A newer answer may have replaced this message while it downloaded.
            guard cache.messages.contains(where: { $0.id == message.id && $0.htmlVersion == page.version }) else {
                store.deletePage(page.file)
                continue
            }
            cache.pages[message.id] = page
            store.writeCache(cache)
        }
    }

    // MARK: Show

    /// Shows the first eligible cached message for `trigger`; false when none can show now.
    func show(_ trigger: InAppRules.Trigger) -> Bool {
        guard overlay == nil, let host = Self.hostWindow(), let scene = host.windowScene,
              let pick = InAppRules.pick(cache, trigger: trigger, now: Date(), target: frame(of:)) else { return false }
        guard let html = store.readPage(pick.page.file) else {
            cache.pages[pick.message.id] = nil
            store.writeCache(cache)
            return false
        }
        let insets = host.safeAreaInsets
        let values = InAppPage.Values(
            insets: (insets.top, insets.right, insets.bottom, insets.left),
            island: InAppRules.island(topInset: insets.top, size: host.bounds.size, isPhone: UIDevice.current.userInterfaceIdiom == .phone),
            target: pick.target, light: pick.page.light, posture: postureSource.posture(windowSize: host.bounds.size))
        let id = pick.message.id
        overlay = InAppOverlay(scene: scene, html: InAppPage.prepare(html, origins: cache.allowedOrigins, values: values),
                               posture: values.posture, postureSource: postureSource,
                               onEvent: { [weak self] event in self?.record(event, messageId: id) },
                               onClose: { [weak self] in self?.overlay = nil })
        return true
    }

    /// Queues an event and, for `shown`, adds one to this device's count.
    private func record(_ event: InAppShowing.Event, messageId: String) {
        if event.type == "shown" {
            cache.shown[messageId, default: 0] += 1
            store.writeCache(cache)
        }
        PushPilot.run { $0.trackInApp(event.type, messageId: messageId, buttonId: event.buttonId, at: event.at) }
    }

    /// The key window of the foreground scene, preferring an active one; nil when the app is not in the foreground.
    private static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
        return scene.flatMap { $0.windows.first { $0.isKeyWindow } ?? $0.windows.first }
    }

    // MARK: Coach marks

    /// Remembers `view` under `name`, weakly; a later view with the same name replaces it.
    func mark(_ view: UIView, name: String) { marks.setObject(view, forKey: name as NSString) }

    /// Forgets the view marked `name`.
    func unmark(name: String) { marks.removeObject(forKey: name as NSString) }

    /// The on-screen frame of the view marked `name`, in window coordinates.
    private func frame(of name: String) -> CGRect? {
        marks.object(forKey: name as NSString).flatMap(Self.visibleFrame)
    }

    /// A view's frame in its window's coordinates when it is in a window, shown (it and every ancestor not hidden
    /// and not transparent) and wholly on screen; nil otherwise.
    static func visibleFrame(_ view: UIView) -> CGRect? {
        guard let window = view.window, !window.isHidden else { return nil }
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha < 0.01 { return nil }
            current = v.superview
        }
        let frame = view.convert(view.bounds, to: nil)
        guard !frame.isEmpty, window.bounds.insetBy(dx: -0.5, dy: -0.5).contains(frame) else { return nil }
        return frame
    }
}
#endif
