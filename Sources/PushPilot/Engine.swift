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
}

/// The sync engine. Not thread-safe: every method runs on the SDK's serial queue.
final class Engine {
    static let coalesceDelay: TimeInterval = 1
    static let staleAfter: TimeInterval = 24 * 60 * 60
    static let maxBackoff: TimeInterval = 5 * 60

    private let sdkKey: String
    private let baseUrl: URL
    private let storage: Storage
    private let network: Network
    private let clock: Clock
    private let device: DeviceInfo
    private let jitter: () -> Double
    private(set) var installationId: String
    private(set) var state: State
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

    /// Queues deletion of this installation on the server and starts over with a new id,
    /// which is registered only after the next setter call or launch.
    func forget() {
        let old = installationId
        installationId = UUID().uuidString.lowercased()
        do { try storage.writeInstallationId(installationId) } catch {
            log.error("forget could not store the new installation id: \(error.localizedDescription, privacy: .public)")
        }
        update { $0 = State(pendingForgets: $0.pendingForgets + [old]) }
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

    /// Sends pending forgets first, then the current state if it changed or the last sync is over 24 hours old.
    private func flush() {
        again = false
        if let forgotten = state.pendingForgets.first {
            return post("forget", ["installation_id": .string(forgotten)]) { [self] _ in
                state.pendingForgets.removeAll { $0 == forgotten }
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
                settled(reply.body)
            case .success(let reply) where reply.status != 429 && (400..<500).contains(reply.status):
                log.error("PushPilot \(path, privacy: .public) rejected with HTTP \(reply.status); not retrying")
                settled(nil)
            case .success(let reply):
                retry(after: reply.retryAfter, reason: "HTTP \(reply.status)")
            case .failure(let error):
                retry(after: nil, reason: error.localizedDescription)
            }
        }
    }

    /// Schedules the next attempt: 1 s doubling to 5 min with jitter, and never sooner than `Retry-After`.
    private func retry(after retryAfter: TimeInterval?, reason: String) {
        failures += 1
        let backoff = min(Self.maxBackoff, pow(2, Double(failures - 1)) * jitter())
        let delay = max(retryAfter ?? 0, backoff)
        log.info("Sync failed (\(reason, privacy: .public)); retrying in \(Int(delay)) s")
        clock.schedule(after: delay) { [self] in flush() }
    }
}
