import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// A JSON value inside a live activity: layouts and field values travel as plain JSON.
public enum LiveJSON: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([LiveJSON])
    case object([String: LiveJSON])

    /// Decodes whichever JSON type is present.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([LiveJSON].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: LiveJSON].self))
        }
    }

    /// Encodes the wrapped value as plain JSON.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// The value under `key` of an object, or nil.
    public subscript(key: String) -> LiveJSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// The text of a string, or nil.
    public var string: String? { if case .string(let v) = self { return v } else { return nil } }
    /// The value of a number, or nil.
    public var number: Double? { if case .number(let v) = self { return v } else { return nil } }
    /// The items of an array, or an empty list.
    public var items: [LiveJSON] { if case .array(let v) = self { return v } else { return [] } }
}

/// One field a layout binds to: `kind` is `text`, `number` or `time` (Unix seconds on the device).
public struct LiveField: Codable, Hashable {
    public let name: String
    public let kind: String
}

/// The state shared by every step: `title` and the named field values (LIVE.md "Contract").
public struct LiveState: Codable, Hashable {
    public var title: String
    public var fields: [String: LiveJSON]

    /// A state; used by previews and tests.
    public init(title: String, fields: [String: LiveJSON] = [:]) {
        self.title = title
        self.fields = fields
    }
}

#if canImport(ActivityKit)
/// The attributes of every PushPilot live activity, started by push with `attributes-type`
/// `PushPilotLiveAttributes`. The widget draws `layout` from `ContentState`; customers rarely
/// need this type, except to write their own SwiftUI for it.
@available(iOS 16.1, *)
public struct PushPilotLiveAttributes: ActivityAttributes {
    public typealias ContentState = LiveState

    /// PushPilot's activity id.
    public let activityId: String
    /// The start step's id: taps and live events are recorded against it.
    public let notificationId: String
    public let name: String?
    /// The link a tap opens.
    public let url: String?
    /// `#RRGGBB`.
    public let accent: String?
    public let fields: [LiveField]
    public let layout: LiveJSON

    enum CodingKeys: String, CodingKey {
        case activityId = "activity_id", notificationId = "notification_id", name, url, accent, fields, layout
    }

    /// Attributes for a preview or a test.
    public init(activityId: String, notificationId: String, name: String? = nil, url: String? = nil, accent: String? = nil,
                fields: [LiveField], layout: LiveJSON) {
        self.activityId = activityId
        self.notificationId = notificationId
        self.name = name
        self.url = url
        self.accent = accent
        self.fields = fields
        self.layout = layout
    }
}
#endif
