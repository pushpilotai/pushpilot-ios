import XCTest
@testable import PushPilot
import PushPilotLive

@available(iOS 16.1, *)
final class LiveTests: XCTestCase {
    /// The `attributes` and `content-state` of a start push exactly as the server builds them (LIVE.md "Step 3 as built").
    let attributesJSON = #"""
    {"activity_id":"a1","notification_id":"s1","name":"Ajax v PSV","url":"myapp://m/7?tab=live","accent":"#D2122E",
     "fields":[{"name":"home_score","kind":"number"},{"name":"kick_off","kind":"time"},{"name":"status","kind":"text","max":80},{"name":"progress","kind":"number"}],
     "layout":{"lock":{"type":"row","items":[{"type":"image","url":"https://e.com/{{home_score}}.png"},{"type":"text","text":"{{title}}"},
       {"type":"column","items":[{"type":"timer","field":"kick_off"}]}]},"island":{"minimal":{"type":"icon","name":"pin"}}}}
    """#
    let stateJSON = #"{"title":"Ajax 2-0","fields":{"home_score":2,"kick_off":1767268800,"progress":0.25}}"#

    /// Decodes both the way ActivityKit does: default `JSONDecoder`.
    func decoded() throws -> (PushPilotLiveAttributes, LiveState) {
        (try JSONDecoder().decode(PushPilotLiveAttributes.self, from: Data(attributesJSON.utf8)),
         try JSONDecoder().decode(LiveState.self, from: Data(stateJSON.utf8)))
    }

    /// The attributes and state decode from the server's JSON, with times as Unix seconds.
    func testDecodesTheServersPush() throws {
        let (a, state) = try decoded()
        XCTAssertEqual([a.activityId, a.notificationId, a.name, a.url, a.accent], ["a1", "s1", "Ajax v PSV", "myapp://m/7?tab=live", "#D2122E"])
        XCTAssertEqual(a.fields.map(\.kind), ["number", "time", "text", "number"])
        XCTAssertEqual(state.title, "Ajax 2-0")
        let content = LiveContent(state: state, fields: a.fields, accent: a.accent, appGroup: nil)
        XCTAssertEqual(content.date("kick_off"), Date(timeIntervalSince1970: 1_767_268_800))
        XCTAssertEqual(LiveContent.imageUrls(a.layout), ["https://e.com/{{home_score}}.png"])
    }

    /// Tokens: title, numbers as written, times through the formatter, fallbacks for missing values.
    func testFillsTokens() throws {
        let (a, state) = try decoded()
        let content = LiveContent(state: state, fields: a.fields, accent: nil, appGroup: nil)
        let text = content.fill("{{title}} · {{ home_score }} · {{kick_off}} · {{status|Live}} · {{status}}.") { "at \(Int($0.timeIntervalSince1970))" }
        XCTAssertEqual(text, "Ajax 2-0 · 2 · at 1767268800 · Live · .")
        XCTAssertEqual(content.fill("{{progress}}"), "0.25")
        XCTAssertEqual(content.fill(nil), "")
    }

    /// Progress follows its field, clamped, or runs between two times.
    func testProgress() {
        let state = LiveState(title: "t", fields: ["p": .number(1.5), "from": .number(100), "to": .number(200)])
        let content = LiveContent(state: state, fields: [], accent: nil, appGroup: nil)
        XCTAssertEqual(content.fraction(.object(["value": .string("p")])), 1)
        XCTAssertEqual(content.fraction(.object(["from": .string("from"), "to": .string("to")]), now: Date(timeIntervalSince1970: 125)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(content.fraction(.object(["from": .string("from"), "to": .string("missing")])), 0)
    }

    /// The tap link keeps the activity's own query, carries the start id, and comes back clean.
    func testTapLinkRoundTrip() throws {
        let (a, _) = try decoded()
        let link = try XCTUnwrap(PushPilotLiveActivityWidget.link(a))
        let tap = try XCTUnwrap(LiveTap.parse(link))
        XCTAssertEqual(tap.notificationId, "s1")
        XCTAssertEqual(tap.link?.absoluteString, "myapp://m/7?tab=live")
        let none = PushPilotLiveAttributes(activityId: "a2", notificationId: "s2", fields: [], layout: .null)
        let bare = try XCTUnwrap(LiveTap.parse(try XCTUnwrap(PushPilotLiveActivityWidget.link(none))))
        XCTAssertEqual(bare.notificationId, "s2")
        XCTAssertNil(bare.link)
        XCTAssertNil(LiveTap.parse(URL(string: "myapp://m/7")!))
    }

    /// A live tap records one click against the start and hands back the app's link.
    func testHandleLiveActivityURLRecordsOneClick() throws {
        PushPilot.resetForTesting()
        defer { PushPilot.resetForTesting() }
        let url = URL(string: "myapp://m/7?pushpilot_live=s9")!
        XCTAssertEqual(PushPilot.handleLiveActivityURL(url)?.absoluteString, "myapp://m/7")
        XCTAssertEqual(PushPilot.handleLiveActivityURL(URL(string: "myapp://other")!)?.absoluteString, "myapp://other")
    }

    /// Every icon of the server's list (158) is mapped to an SF Symbol.
    func testIconList() {
        XCTAssertEqual(PushPilotLiveIcons.symbols.count, 158)
        XCTAssertEqual(PushPilotLiveIcons.symbols["pin"], "mappin")
    }

    /// The `live` object: only `supported` and `enabled` when unsupported; the token and flags otherwise.
    func testCapability() throws {
        #if canImport(ActivityKit)
        guard #available(iOS 17.2, *) else { throw XCTSkip("needs iOS 17.2") }
        XCTAssertEqual(LiveObserver.capability(supported: false, enabled: true, startToken: "ab", broadcast: true, appGroup: true),
                       ["supported": .bool(false), "enabled": .bool(false)])
        XCTAssertEqual(LiveObserver.capability(supported: true, enabled: true, startToken: "ab", broadcast: false, appGroup: true),
                       ["supported": .bool(true), "enabled": .bool(true), "start_token": .string("ab"), "broadcast": .bool(false), "app_group": .bool(true)])
        #endif
    }
}

final class LiveEngineTests: XCTestCase {
    let storage = FakeStorage()
    let network = FakeNetwork()
    let clock = FakeClock()
    let device = FakeDevice()

    /// An engine on the fakes, registered once.
    func registered() throws -> Engine {
        let engine = try Engine(sdkKey: "pk", baseUrl: PushPilot.defaultBaseUrl, storage: storage, network: network,
                                clock: clock, device: device, jitter: { 1 })
        engine.setPushToken(tok1)
        clock.advance(Engine.coalesceDelay)
        network.reply()
        return engine
    }

    /// The `live` object rides on sync, a repeat sends nothing, and forget keeps it for the new installation.
    func testLiveObjectSyncs() throws {
        let engine = try registered()
        let live: [String: JSONValue] = ["supported": .bool(true), "enabled": .bool(true), "start_token": .string("c0ffee")]
        engine.setLive(live)
        clock.advance(Engine.coalesceDelay)
        XCTAssertEqual(network.open.first?.url.hasSuffix("/sync/"), true)
        XCTAssertEqual(network.open.first?.body["live"], .object(live))
        network.reply()
        engine.setLive(live)
        clock.advance(Engine.coalesceDelay)
        XCTAssertTrue(network.open.isEmpty)
        engine.forget()
        XCTAssertEqual(engine.state.live, live)
    }

    /// Update tokens go to live/token, never in a sync; a newer token for the same activity wins.
    func testLiveTokenPostsOnce() throws {
        let engine = try registered()
        engine.setLiveToken(activityId: "a1", token: tok1)
        engine.setLiveToken(activityId: "a1", token: tok2)
        clock.advance(Engine.coalesceDelay)
        let call = try XCTUnwrap(network.open.first)
        XCTAssertTrue(call.url.hasSuffix("/live/token/"))
        XCTAssertEqual(call.body, ["installation_id": .string(engine.installationId), "activity_id": .string("a1"), "token": .string(hex2)])
        network.reply(204, json: "")
        XCTAssertNil(engine.state.liveTokens?["a1"])
        XCTAssertFalse(network.all.contains { $0.body["token"] == .string(hex2) && $0.url.hasSuffix("/sync/") })
    }

    /// `live_started` is queued once per activity; `live_dismissed` each time it is reported.
    func testLiveEvents() throws {
        let engine = try registered()
        engine.trackLive("live_started", notificationId: "s1")
        engine.trackLive("live_started", notificationId: "s1")
        engine.trackLive("live_dismissed", notificationId: "s1")
        XCTAssertEqual(engine.state.events?.compactMap { $0["type"] }, [.string("live_started"), .string("live_dismissed")])
        XCTAssertEqual(engine.state.events?.first?["notification_id"], .string("s1"))
    }
}
