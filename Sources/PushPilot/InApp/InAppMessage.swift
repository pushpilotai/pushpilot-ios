import Foundation

/// One message of `GET /api/sdk/v1/in-app/` (IN-APP-SDK.md section 1).
struct InAppMessage: Codable, Equatable {
    let id: String
    let name: String?
    /// `modal`, `full_screen`, …; only `coach_mark` changes what the SDK does.
    let format: String
    /// `app_open` or `show_in_app`.
    let trigger: String
    let triggerName: String?
    let htmlUrl: String
    let lightHtmlUrl: String?
    let htmlVersion: Int
    let assets: [String]?
    let capPerDevice: Int?
    let shownCount: Int?
    let coachTarget: String?
    let startsAt: String?
    let endsAt: String?
}

/// The whole answer of `GET /api/sdk/v1/in-app/`.
struct InAppList: Codable, Equatable {
    let messages: [InAppMessage]
    let allowedOrigins: [String]?

    /// Reads the server's snake_case JSON; nil when it is not the expected shape.
    static func decode(_ data: Data) -> InAppList? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(InAppList.self, from: data)
    }
}

/// A cached page on disk: which version it is, whether it is the light page, and its file name.
struct InAppCachedPage: Codable, Equatable {
    let version: Int
    let light: Bool
    let file: String
}

/// What the SDK keeps on disk between launches: the last answer, the cached pages and its own shown counts.
struct InAppCache: Codable, Equatable {
    /// The last answer's messages, in its order.
    var messages: [InAppMessage] = []
    var allowedOrigins: [String] = []
    /// Message id to its cached page; only fully cached pages (page and every asset) are listed.
    var pages: [String: InAppCachedPage] = [:]
    /// Message id to how often this device showed it.
    var shown: [String: Int] = [:]
}

/// RFC 3339 times for in-app messages and events.
enum InAppDates {
    /// Formats with milliseconds, for event `at`.
    static func format(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Parses a server time with or without fractional seconds (PostgreSQL sends microseconds); nil if unreadable.
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        // Fractions longer than ISO8601DateFormatter reads: keep the first three digits.
        guard let dot = text.firstIndex(of: "."), let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) else { return nil }
        let digits = text[text.index(after: dot)..<end]
        let trimmed = text[..<dot] + "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0) + text[end...]
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: String(trimmed))
    }
}
