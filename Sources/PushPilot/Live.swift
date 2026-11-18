#if canImport(ActivityKit)
import ActivityKit
import Foundation
import PushPilotLive

/// Watches PushPilot live activities for the app (LIVE.md "Design: SDKs"): reports whether they
/// can be started by push and the push-to-start token, each activity's update token, `live_started`
/// and `live_dismissed`; downloads layout images into the App Group; and ends activities past their
/// end. Push-to-start needs iOS 17.2. State lives on the SDK queue.
@available(iOS 17.2, *)
enum LiveObserver {
    private static var running = false
    private static var appGroup: String?
    private static var startToken: String?
    private static var enabled = false
    private static var observed: Set<String> = []

    /// Starts watching once per process; `appGroup` is the group shared with the Widget Extension.
    static func start(appGroup: String?) {
        PushPilot.queue.async {
            guard !running else { return }
            running = true
            self.appGroup = appGroup
            enabled = ActivityAuthorizationInfo().areActivitiesEnabled
            report()
            Task {
                for await on in ActivityAuthorizationInfo().activityEnablementUpdates {
                    PushPilot.queue.async { enabled = on; report() }
                }
            }
            Task {
                for await token in Activity<PushPilotLiveAttributes>.pushToStartTokenUpdates {
                    PushPilot.queue.async { startToken = Engine.hex(token); report() }
                }
            }
            Task {
                for activity in Activity<PushPilotLiveAttributes>.activities { observe(activity) }
                for await activity in Activity<PushPilotLiveAttributes>.activityUpdates { observe(activity) }
            }
        }
    }

    /// Whether the app declares `NSSupportsLiveActivities`, without which iOS starts none.
    static var supported: Bool { Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true }

    /// The `live` object of register and sync (LIVE.md "Step 1 as built").
    static func capability(supported: Bool, enabled: Bool, startToken: String?, broadcast: Bool, appGroup: Bool) -> [String: JSONValue] {
        guard supported else { return ["supported": .bool(false), "enabled": .bool(false)] }
        var live: [String: JSONValue] = ["supported": .bool(true), "enabled": .bool(enabled), "broadcast": .bool(broadcast), "app_group": .bool(appGroup)]
        if let startToken { live["start_token"] = .string(startToken) }
        return live
    }

    /// Hands the current capability to the engine, which syncs when it changed.
    private static func report() {
        let group = appGroup.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) } != nil
        let broadcast: Bool
        if #available(iOS 18.0, *) { broadcast = true } else { broadcast = false }
        let live = capability(supported: supported, enabled: enabled, startToken: startToken, broadcast: broadcast, appGroup: group)
        PushPilot.run { $0.setLive(live) }
    }

    /// Follows one activity: ends it when past its end, else reports it started, its tokens, a dismissal and its images.
    private static func observe(_ activity: Activity<PushPilotLiveAttributes>) {
        PushPilot.queue.async {
            guard observed.insert(activity.id).inserted else { return }
            let a = activity.attributes
            if activity.activityState == .active, let stale = activity.content.staleDate, stale < Date() {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
                return
            }
            log.notice("Live activity observed")
            PushPilot.run { $0.trackLive("live_started", notificationId: a.notificationId) }
            Task {
                for await token in activity.pushTokenUpdates {
                    log.notice("Live activity update token received (\(token.count) bytes)")
                    PushPilot.run { $0.setLiveToken(activityId: a.activityId, token: token) }
                }
            }
            Task {
                var ended = activity.activityState == .ended
                for await state in activity.activityStateUpdates {
                    if userDismissed(state, ended: ended, staleDate: activity.content.staleDate, now: Date()) {
                        PushPilot.run { $0.trackLive("live_dismissed", notificationId: a.notificationId) }
                    }
                    ended = ended || state == .ended
                }
            }
            let group = appGroup
            Task {
                await download(a, activity.content.state, group)
                for await content in activity.contentUpdates { await download(a, content.state, group) }
            }
        }
    }

    /// Whether a state change is the person's dismissal: `.dismissed` before the activity ended. An
    /// end the app slept through arrives as `.dismissed` alone, so past the stale date (the
    /// activity's end) it is the system's removal. shortcut: an early end slept through still looks
    /// like a swipe here; the server drops `live_dismissed` for an instance it has ended.
    static func userDismissed(_ state: ActivityState, ended: Bool, staleDate: Date?, now: Date) -> Bool {
        state == .dismissed && !ended && !(staleDate.map { $0 <= now } ?? false)
    }

    /// Downloads the layout's https images (tokens filled) into the App Group, at most four of 512 KB each.
    private static func download(_ a: PushPilotLiveAttributes, _ state: LiveState, _ group: String?) async {
        guard let group else { return }
        let content = LiveContent(state: state, fields: a.fields, accent: a.accent, appGroup: group)
        let urls = LiveContent.imageUrls(a.layout).map { content.fill($0) }.filter { $0.hasPrefix("https://") }
        for url in Array(Set(urls)).sorted().prefix(4) {
            guard let file = LiveContent.imageFile(url: url, appGroup: group), !FileManager.default.fileExists(atPath: file.path),
                  let remote = URL(string: url) else { continue }
            var request = URLRequest(url: remote)
            request.timeoutInterval = 10
            guard let (data, reply) = try? await URLSession.shared.data(for: request),
                  (reply as? HTTPURLResponse)?.statusCode == 200, data.count <= 512 * 1024 else { continue }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }
}
#endif

/// Reads the tap link of a live activity (see `PushPilotLiveActivityWidget.link`).
enum LiveTap {
    /// The start step's id the link carries, and the app's own link without it (nil when the activity had none).
    static func parse(_ url: URL) -> (notificationId: String, link: URL?)? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let id = parts.queryItems?.first(where: { $0.name == LiveLink.marker })?.value, !id.isEmpty else { return nil }
        if parts.scheme == "pushpilot-live" { return (id, nil) }
        let rest = parts.queryItems?.filter { $0.name != LiveLink.marker } ?? []
        parts.queryItems = rest.isEmpty ? nil : rest
        return (id, parts.url)
    }
}
