import Foundation

/// A JSON value, so payloads can be stored on disk, compared and sent exactly as built.
enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// Decodes whichever JSON type is present.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Double.self) {
            self = .number(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    /// Encodes the wrapped value as plain JSON.
    func encode(to encoder: Encoder) throws {
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

    /// Converts an attribute value from the app: String, Bool, number, Date or nil (removes the attribute).
    /// Returns nil for any other type.
    static func attribute(_ value: Any?) -> JSONValue? {
        guard let value, !(value is NSNull) else { return .null }
        switch value {
        case let v as String:
            return .string(v)
        case let v as Date:
            return .string(ISO8601DateFormatter().string(from: v))
        case let v as NSNumber:
            // Swift Bool bridges to CFBoolean and Int/Double to CFNumber, which tells them apart.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { return .bool(v.boolValue) }
            return v.doubleValue.isFinite ? .number(v.doubleValue) : nil
        default:
            return nil
        }
    }
}
