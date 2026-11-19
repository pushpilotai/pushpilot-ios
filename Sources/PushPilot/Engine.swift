import Foundation
import os

let log = Logger(subsystem: "ai.pushpilot.sdk", category: "PushPilot")

/// Disk and Keychain access. `read` methods return nil when nothing is stored and throw when
/// storage cannot be read right now (for example before the first unlock after a reboot).
protocol Storage {
    func readInstallationId() throws -> String?
    func writeInstallationId(_ id: String) throws
    func readState() throws -> State?
    func writeState(_ state: State) throws
    func readConfig() throws -> SavedConfig?
    func writeConfig(_ config: SavedConfig) throws
}

/// The SDK key and server from the last `initialize`, so a process the app has not initialised yet
/// (a tap that launched a killed app, an early token) can start the SDK itself.
struct SavedConfig: Codable, Equatable {
    let sdkKey: String
    let baseUrl: URL
}

/// One HTTP answer: status, `Retry-After` in seconds when present, and body.
struct HTTPReply {
    let status: Int
    let retryAfter: TimeInterval?
    let body: Data
}

/// Sends one POST with the SDK key; calls back on the SDK queue.
protocol Network {
    func post(_ url: URL, sdkKey: String, body: Data, completion: @escaping (Result<HTTPReply, Error>) -> Void)
}

/// Current time and delayed work on the SDK queue.
protocol Clock {
    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void)
}

/// Reads the automatic fields (OS, app and SDK versions, model, locale, timezone, permission) and the
/// build's APNs environment as `apns_environment`; calls back on the SDK queue.
protocol DeviceInfo {
    func collect(_ completion: @escaping ([String: JSONValue]) -> Void)
}

/// Everything the SDK keeps on disk between launches.
struct State: Codable, Equatable {
    var token: String?
    var externalUserId: String?
    /// nil until the app calls `setTopics`, so the server keeps its value until then.
    var topics: [String]?
    /// Accumulated attribute values; `.null` entries tell the server to remove that attribute.
    var attributes: [String: JSONValue] = [:]
    /// The last payload the server gave a final answer to, and when.
    var lastSent: [String: JSONValue]?
    var lastSentAt: Date?
    /// Installation ids whose server record still has to be deleted.
    var pendingForgets: [String] = []
    /// Tracking events not yet accepted by the server, oldest first. Optional so state saved before v2 still loads.
    var events: [[String: JSONValue]]?
    /// The `live` object of register and sync; nil until live activities are watched (iOS 17.2+).
    var live: [String: JSONValue]?
    /// Live activity update tokens (activity id to hex) not yet accepted by the server.
    var liveTokens: [String: String]?
    /// Start step ids already reported as `live_started`, newest last.
    var liveStarted: [String]?
    /// In-app message events (IN-APP-SDK.md section 7) not yet accepted by the server, oldest first.
    var inAppEvents: [[String: JSONValue]]?
}

/// The sync engine. Not thread-safe: every method runs on the SDK's serial queue.
final class Engine {
    static let coalesceDelay: TimeInterval = 1
    static let staleAfter: TimeInterval = 24 * 60 * 60
    static let maxBackoff: TimeInterval = 5 * 60
    /// Events kept on disk at most; the oldest are dropped beyond this.
    static let maxQueuedEvents = 500
    /// Events per request, the server's limit.
    static let eventsPerRequest = 100

    /// Replaced when an explicit `initialize` follows a start from the saved configuration.
    var sdkKey: String
    var baseUrl: URL
    private let storage: Storage
    private let network: Network
    private let clock: Clock
    private let device: DeviceInfo
    private let jitter: () -> Double
    private(set) var installationId: String
    private(set) var state: State
    /// The outcome of the last register or sync request in this process, for `PushPilot.status`; nil before one.
    private(set) var lastSyncResult: String?
    private var failures = 0
    /// A send is scheduled or in flight; new changes wait for it.
    private var busy = false
    /// State changed while busy, so another pass is needed afterwards.
    private var again = false
    /// Set by forget(): the new id is not registered until a setter runs. In memory only, so the next launch registers it.
    private var holdAfterForget = false

    /// Loads saved state and the installation id, creating the id on first run. Throws if storage is unavailable.
    init(sdkKey: String, baseUrl: URL, storage: Storage, network: Network, clock: Clock, device: DeviceInfo,
         jitter: @escaping () -> Double = { Double.random(in: 1...1.25) }) throws {
        self.sdkKey = sdkKey
        self.baseUrl = baseUrl
        self.storage = storage
        self.network = network
        self.clock = clock
        self.device = device
        self.jitter = jitter
        state = try storage.readState() ?? State()
        if let id = try storage.readInstallationId() {
            installationId = id
        } else {
            installationId = UUID().uuidString.lowercased()
            try storage.writeInstallationId(installationId)
        }
    }

    // MARK: App calls

    /// Stores the APNs device token as lowercase hex; nil or empty clears it so the device stops receiving pushes.
    func setPushToken(_ deviceToken: Data?) {
        guard (deviceToken?.count ?? 0) <= 2048 else { return log.error("setPushToken ignored: token is longer than 2048 bytes") }
        let hex = deviceToken.map(Self.hex)
        update { $0.token = hex?.isEmpty == false ? hex : nil }
    }

    /// Lowercase hex, the form APNs expects in its request path.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Stores the app's own user id, 1 to 255 characters.
    func setExternalUserId(_ id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...255).contains(id.count) else { return log.error("setExternalUserId ignored: id must be 1 to 255 characters") }
        update { $0.externalUserId = id }
    }

    /// Merges attribute values; nil removes one. Values of unsupported types are skipped.
    func setAttributes(_ attributes: [String: Any?]) {
        var converted: [String: JSONValue] = [:]
        for (name, value) in attributes {
            guard let json = JSONValue.attribute(value) else {
                log.error("setAttributes skipped \(name, privacy: .public): use String, Bool, a number, Date or nil")
                continue
            }
            converted[name] = json
        }
        update { $0.attributes.merge(converted) { $1 } }
    }

    /// Replaces the device's topics. Invalid names are dropped (the server would reject the whole sync),
    /// the rest are de-duplicated and sorted, and only the first 100 are kept.
    func setTopics(_ topics: [String]) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~%")
        let valid = topics.filter { (1...255).contains($0.count) && $0.allSatisfy(allowed.contains) }
        let unique = Set(valid).sorted()
        if valid.count < topics.count {
            log.error("setTopics dropped \(topics.count - valid.count) invalid names: use 1 to 255 letters, digits or -_.~%")
        }
        if unique.count > 100 { log.error("setTopics kept the first 100 of \(unique.count) topics") }
        update { $0.topics = Array(unique.prefix(100)) }
    }

    /// Clears the external user id; the device stays registered.
    func logout() {
        update { $0.externalUserId = nil }
    }

    /// Queues a `clicked` event for a notification, with the button id when a button was tapped.
    /// Not a setter: it does not end the hold after `forget()`.
    func trackClick(notificationId: String, buttonId: String?) {
        queueEvent("clicked", notificationId: notificationId, buttonId: buttonId)
    }

    /// Queues `live_started` (once per activity) or `live_dismissed` against the activity's start step.
    func trackLive(_ type: String, notificationId: String) {
        if type == "live_started" {
            guard !(state.liveStarted ?? []).contains(notificationId) else { return }
            state.liveStarted = Array(((state.liveStarted ?? []) + [notificationId]).suffix(100))
        }
        queueEvent(type, notificationId: notificationId, buttonId: nil)
    }

    /// Stores the `live` object and syncs when it changed. Not a setter: it does not end the hold after `forget()`.
    func setLive(_ live: [String: JSONValue]) {
        guard state.live != live else { return }
        state.live = live
        save()
        requestSync()
    }

    /// Queues an activity's update token for `live/token`; a newer token for the same activity replaces it.
    func setLiveToken(activityId: String, token: Data) {
        var tokens = state.liveTokens ?? [:]
        tokens[activityId] = Self.hex(token)
        state.liveTokens = tokens
        save()
        requestSync()
    }

    /// Queues an in-app `shown`, `clicked` or `dismissed` event; `at` is the moment it happened.
    /// Not a setter: it does not end the hold after `forget()`.
    func trackInApp(_ type: String, messageId: String, buttonId: String?, at: Date) {
        var event: [String: JSONValue] = [
            "message_id": .string(messageId),
            "installation_id": .string(installationId),
            "type": .string(type),
            // Fractional seconds, so two showings in one second stay two showings on the server.
            "at": .string(InAppDates.format(at)),
        ]
        if let buttonId { event["button_id"] = .string(buttonId) }
        state.inAppEvents = Array(((state.inAppEvents ?? []) + [event]).suffix(Self.maxQueuedEvents))
        save()
        requestSync()
    }

    /// Adds one event to the queue on disk and asks for a send.
    private func queueEvent(_ type: String, notificationId: String, buttonId: String?) {
        var event: [String: JSONValue] = [
            "notification_id": .string(notificationId),
            "installation_id": .string(installationId),
            "type": .string(type),
            "at": .string(ISO8601DateFormatter().string(from: clock.now)),
        ]
        if let buttonId { event["button_id"] = .string(buttonId) }
        state.events = Array(((state.events ?? []) + [event]).suffix(Self.maxQueuedEvents))
        save()
        requestSync()
    }

    /// Queues deletion of this installation on the server and starts over with a new id,
    /// which is registered only after the next setter call or launch.
    func forget() {
        let old = installationId
        installationId = UUID().uuidString.lowercased()
        do { try storage.writeInstallationId(installationId) } catch {
            log.error("forget could not store the new installation id: \(error.localizedDescription, privacy: .public)")
        }
        // The device's live capability is not about the user, so it carries over to the new installation.
        update { $0 = State(pendingForgets: $0.pendingForgets + [old], live: $0.live) }
        holdAfterForget = true
    }

    /// Asks for a sync soon; changes made in the next second ride along in the same request.
    func requestSync() {
        guard !busy else { again = true; return }
        busy = true
        clock.schedule(after: Self.coalesceDelay) { [self] in flush() }
    }

    // MARK: Sync

    /// Applies a change, saves it, and asks for a sync.
    private func update(_ change: (inout State) -> Void) {
        holdAfterForget = false
        change(&state)
        save()
        requestSync()
    }

    /// Saves state; a failed write only loses changes if the app is killed before the next save.
    private func save() {
        do { try storage.writeState(state) } catch {
            log.error("Could not save state: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends pending forgets first, then queued events in batches, then the current state if it changed
    /// or the last sync is over 24 hours old.
    private func flush() {
        again = false
        if let forgotten = state.pendingForgets.first {
            return post("forget", ["installation_id": .string(forgotten)]) { [self] _ in
                state.pendingForgets.removeAll { $0 == forgotten }
                save()
                flush()
            }
        }
        if let (activity, token) = state.liveTokens?.min(by: { $0.key < $1.key }) {
            let body: [String: JSONValue] = ["installation_id": .string(installationId), "activity_id": .string(activity), "token": .string(token)]
            // Accepted or rejected, this token is done unless a newer one replaced it meanwhile.
            return post("live/token", body) { [self] reply in
                if reply != nil { log.notice("Live activity update token sent") }
                if state.liveTokens?[activity] == token { state.liveTokens?[activity] = nil }
                save()
                flush()
            }
        }
        if let events = state.events, !events.isEmpty {
            let batch = Array(events.prefix(Self.eventsPerRequest))
            // Accepted or rejected (4xx), the batch is done; 429, 5xx and network errors retry it.
            return post("events", ["events": .array(batch.map(JSONValue.object))]) { [self] _ in
                state.events?.removeAll { batch.contains($0) }
                save()
                flush()
            }
        }
        if let events = state.inAppEvents, !events.isEmpty {
            let batch = Array(events.prefix(Self.eventsPerRequest))
            // Same rules as push events: done when accepted or rejected, the same batch again after a failure.
            return post("in-app/events", ["events": .array(batch.map(JSONValue.object))]) { [self] _ in
                state.inAppEvents?.removeAll { batch.contains($0) }
                save()
                flush()
            }
        }
        device.collect { [self] fields in
            let payload = payload(fields)
            let fresh = state.lastSentAt.map { clock.now.timeIntervalSince($0) < Self.staleAfter } ?? false
            if (payload == state.lastSent && fresh) || holdAfterForget {
                return finish()
            }
            let path = state.lastSent?["installation_id"] == payload["installation_id"] ? "sync" : "register"
            syncPath = path
            post(path, payload) { [self] reply in record(payload, reply: reply) }
        }
    }

    /// The full state the server should hold for this installation.
    private func payload(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        var p = fields
        // The environment only means something with a token, so both travel with it.
        let environment = p.removeValue(forKey: "apns_environment")
        if let token = state.token {
            p["token"] = .string(token)
            p["token_kind"] = .string("apns")
            p["apns_environment"] = environment
        } else {
            p["token"] = .null
        }
        p["installation_id"] = .string(installationId)
        p["external_user_id"] = state.externalUserId.map(JSONValue.string) ?? .null
        if let topics = state.topics { p["topics"] = .array(topics.map(JSONValue.string)) }
        if !state.attributes.isEmpty { p["attributes"] = .object(state.attributes) }
        if let live = state.live { p["live"] = .object(live) }
        return p
    }

    /// Remembers what the server accepted, adopts a replacement installation id, and logs warnings.
    private func record(_ payload: [String: JSONValue], reply: Data?) {
        // forget() ran while this was in flight; the old id's result no longer matters.
        guard payload["installation_id"] == .string(installationId) else { return finish() }
        var sent = payload
        struct Reply: Decodable { let installation_id: String?; let warnings: [String]? }
        if let reply, let decoded = try? JSONDecoder().decode(Reply.self, from: reply) {
            if let id = decoded.installation_id?.lowercased(), UUID(uuidString: id) != nil, id != installationId {
                installationId = id
                sent["installation_id"] = .string(id)
                do { try storage.writeInstallationId(id) } catch {
                    log.error("Could not store the replacement installation id: \(error.localizedDescription, privacy: .public)")
                }
            }
            for warning in decoded.warnings ?? [] { log.warning("Server: \(warning, privacy: .public)") }
        }
        state.lastSent = sent
        state.lastSentAt = clock.now
        save()
        finish()
    }

    /// The register or sync request in flight, so its outcome is kept in `lastSyncResult`.
    private var syncPath: String?

    /// Keeps the outcome of a register or sync request; other requests leave it as it was.
    private func noteSync(_ path: String, _ outcome: String) {
        guard path == syncPath else { return }
        lastSyncResult = "\(path): \(outcome)"
    }

    /// Ends a pass and starts another if state changed meanwhile.
    private func finish() {
        busy = false
        failures = 0
        if again { requestSync() }
    }

    /// POSTs to an SDK endpoint. Calls `settled` with the body on success, or nil when the server
    /// rejected the request (4xx other than 429), which is not retried. Anything else is retried with backoff.
    private func post(_ path: String, _ body: [String: JSONValue], settled: @escaping (Data?) -> Void) {
        let url = baseUrl.appendingPathComponent("api/sdk/v1/\(path)/")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(body) else { return settled(nil) }
        network.post(url, sdkKey: sdkKey, body: data) { [self] result in
            switch result {
            case .success(let reply) where (200..<300).contains(reply.status):
                noteSync(path, "OK (HTTP \(reply.status))")
                settled(reply.body)
            case .success(let reply) where reply.status != 429 && (400..<500).contains(reply.status):
                log.error("PushPilot \(path, privacy: .public) rejected with HTTP \(reply.status); not retrying")
                noteSync(path, "rejected (HTTP \(reply.status))")
                settled(nil)
            case .success(let reply):
                noteSync(path, "failed (HTTP \(reply.status)), retrying")
                retry(after: reply.retryAfter, reason: "\(path): HTTP \(reply.status)")
            case .failure(let error):
                noteSync(path, "failed (\(error.localizedDescription)), retrying")
                retry(after: nil, reason: "\(path): \(error.localizedDescription)")
            }
        }
    }

    /// Schedules the next attempt: 1 s doubling to 5 min with jitter, and never sooner than `Retry-After`.
    private func retry(after retryAfter: TimeInterval?, reason: String) {
        failures += 1
        let backoff = min(Self.maxBackoff, pow(2, Double(failures - 1)) * jitter())
        let delay = max(retryAfter ?? 0, backoff)
        log.notice("Send failed (\(reason, privacy: .public)); retrying in \(Int(delay)) s")
        clock.schedule(after: delay) { [self] in flush() }
    }
}
