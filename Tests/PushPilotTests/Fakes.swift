import Foundation
@testable import PushPilot

/// In-memory Keychain and state file.
final class FakeStorage: Storage {
    var id: String?
    var state: State?
    /// Reads the stored id.
    func readInstallationId() throws -> String? { id }
    /// Stores the id.
    func writeInstallationId(_ id: String) throws { self.id = id }
    /// Reads the stored state.
    func readState() throws -> State? { state }
    /// Stores the state.
    func writeState(_ state: State) throws { self.state = state }
}

/// A clock that only moves when the test says so.
final class FakeClock: Clock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var timers: [(at: Date, work: () -> Void)] = []

    /// Queues `work` to run when time reaches now + seconds.
    func schedule(after seconds: TimeInterval, _ work: @escaping () -> Void) {
        timers.append((now + seconds, work))
    }

    /// Moves time forward, running every timer that comes due, earliest first.
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = timers.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
            timers.remove(at: next.offset)
            now = max(now, next.element.at)
            next.element.work()
        }
        now = end
    }

    /// Seconds until the earliest pending timer, if any.
    var nextDelay: TimeInterval? { timers.map { $0.at.timeIntervalSince(now) }.min() }
}

/// Records requests and lets the test answer them one at a time.
final class FakeNetwork: Network {
    struct Call {
        let url: String
        let sdkKey: String
        let body: [String: JSONValue]
        let done: (Result<HTTPReply, Error>) -> Void
    }
    /// Requests not yet answered, oldest first.
    var open: [Call] = []
    /// Every request ever made.
    var all: [Call] = []

    /// Records the request; it stays open until `reply` or `fail`.
    func post(_ url: URL, sdkKey: String, body: Data, completion: @escaping (Result<HTTPReply, Error>) -> Void) {
        let decoded = (try? JSONDecoder().decode([String: JSONValue].self, from: body)) ?? [:]
        let call = Call(url: url.absoluteString, sdkKey: sdkKey, body: decoded, done: completion)
        open.append(call)
        all.append(call)
    }

    /// Answers the oldest open request; a 200 echoes its installation id like the server does.
    func reply(_ status: Int = 200, retryAfter: TimeInterval? = nil, json: String? = nil) {
        let call = open.removeFirst()
        var body = json ?? ""
        if json == nil, status == 200, case .string(let id)? = call.body["installation_id"] {
            body = #"{"installation_id":"\#(id)","throttled":false,"warnings":[]}"#
        }
        call.done(.success(HTTPReply(status: status, retryAfter: retryAfter, body: Data(body.utf8))))
    }

    /// Fails the oldest open request as if the device were offline.
    func fail() {
        open.removeFirst().done(.failure(URLError(.notConnectedToInternet)))
    }
}

/// Fixed automatic fields with a permission the test can change.
final class FakeDevice: DeviceInfo {
    var permission = "granted"
    /// Returns the fields synchronously.
    func collect(_ completion: @escaping ([String: JSONValue]) -> Void) {
        completion(Self.fields(permission))
    }
    /// The fields every sync carries in these tests.
    static func fields(_ permission: String) -> [String: JSONValue] {
        [
            "notification_permission": .string(permission),
            "os_version": .string("17.2"),
            "app_version": .string("3.1"),
            "sdk_version": .string("1.0.0"),
            "device_model": .string("iPhone15,2"),
            "locale": .string("en-US"),
            "timezone": .string("Europe/Berlin"),
        ]
    }
}
