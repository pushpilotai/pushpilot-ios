import Foundation
import XCTest
@testable import PushPilotLive

/// The reference designs of layout contract version 2 (copied from the server's `backend-rust/src/live/designs`),
/// turned into what a device receives: attributes and a `content-state` with times as Unix seconds.
enum LiveDesigns {
    /// One reference design as the device sees it.
    struct Design {
        let name: String
        let raw: [String: Any]
        let attributes: Data
        let state: Data
    }

    /// The design file names, without `.json`.
    static var names: [String] {
        let dir = Bundle.module.url(forResource: "designs", withExtension: nil)!
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Loads a design; time fields become `now` plus `timeOffset` seconds so timers show a stable value.
    static func load(_ name: String, now: Date = Date(), timeOffset: TimeInterval = 312) throws -> Design {
        let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "designs")!
        let raw = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let fields = try XCTUnwrap(raw["fields"] as? [[String: Any]])
        let attributes: [String: Any] = ["activity_id": "a-\(name)", "notification_id": "s-\(name)", "name": raw["name"] ?? name,
                                         "accent": "#0A84FF", "fields": fields, "layout": raw["layout"] ?? [:]]
        var state = try XCTUnwrap(raw["state"] as? [String: Any])
        let title = state.removeValue(forKey: "title") ?? ""
        for field in fields where field["kind"] as? String == "time" {
            if let name = field["name"] as? String, state[name] != nil { state[name] = now.timeIntervalSince1970 + timeOffset }
        }
        return Design(name: name, raw: raw, attributes: try JSONSerialization.data(withJSONObject: attributes),
                      state: try JSONSerialization.data(withJSONObject: ["title": title, "fields": state]))
    }

    /// Every block of a layout tree: regions, defs, items, markers and grid tiles.
    static func blocks(_ json: LiveJSON) -> [LiveJSON] {
        guard case .object(let o) = json else { return json.items.flatMap(blocks) }
        let own = o["type"] == nil ? [] : [json]
        let nested = o.filter { $0.key != "promoted" && $0.key != "runs" }.values.flatMap { value -> [LiveJSON] in
            if case .object = value { return blocks(value) }
            return value.items.flatMap(blocks)
        }
        return own + nested
    }
}
