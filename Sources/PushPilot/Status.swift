import Foundation

/// What the SDK has reported for this installation, for a status or debug screen. It holds no push
/// token, live activity token or key.
public struct PushPilotStatus: Equatable {
    public let installationId: String
    public let baseUrl: URL
    /// From the `live` object the SDK reports; all nil before it watches live activities (iOS below 17.2).
    public let liveSupported: Bool?
    public let liveEnabled: Bool?
    /// The App Group's container could be opened, so layout images can reach the widget.
    public let liveAppGroup: Bool?
    /// The server has accepted a sync carrying a push-to-start token.
    public let liveStartTokenReported: Bool
    /// When the server last accepted a register or sync, and the outcome of the last one tried in this process.
    public let lastSyncAt: Date?
    public let lastSyncResult: String?
}

extension PushPilot {
    /// Calls `completion` on the main queue with what the SDK has reported. Before `initialize` (and
    /// with no saved configuration) it waits until the SDK starts.
    public static func status(_ completion: @escaping (PushPilotStatus) -> Void) {
        run { engine in
            let status = engine.status
            DispatchQueue.main.async { completion(status) }
        }
    }
}

extension Engine {
    /// The status as of now; the live flags come from the object the SDK reports.
    var status: PushPilotStatus {
        /// A bool of the reported `live` object, or nil when there is none.
        func flag(_ name: String) -> Bool? {
            if case .bool(let value)? = state.live?[name] { return value }
            return nil
        }
        var reported = false
        if case .object(let sent)? = state.lastSent?["live"], case .string? = sent["start_token"] { reported = true }
        return PushPilotStatus(installationId: installationId, baseUrl: baseUrl, liveSupported: flag("supported"),
                               liveEnabled: flag("enabled"), liveAppGroup: flag("app_group"), liveStartTokenReported: reported,
                               lastSyncAt: state.lastSentAt, lastSyncResult: lastSyncResult)
    }
}
