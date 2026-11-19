import XCTest
@testable import PushPilot
#if canImport(UIKit)
import UIKit
#endif

/// The pure parts of in-app messages (IN-APP-SDK.md): decoding, cache, page building, eligibility, island, bridge and events.
final class InAppTests: XCTestCase {
    let id1 = "6f1c2b8e-0000-4000-8000-000000000001"
    let id2 = "6f1c2b8e-0000-4000-8000-000000000002"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A message with the given fields and the rest defaulted.
    func message(_ id: String, trigger: String = "app_open", name: String? = nil, format: String = "modal", version: Int = 1,
                 cap: Int? = nil, shown: Int = 0, coach: String? = nil, starts: String? = nil, ends: String? = nil,
                 light: String? = nil, assets: [String] = []) -> InAppMessage {
        InAppMessage(id: id, name: "M", format: format, trigger: trigger, triggerName: name, htmlUrl: "https://cdn.test/\(id).html",
                     lightHtmlUrl: light, htmlVersion: version, assets: assets, capPerDevice: cap, shownCount: shown,
                     coachTarget: coach, startsAt: starts, endsAt: ends)
    }

    /// A cache holding `messages`, each with its current page cached.
    func cached(_ messages: [InAppMessage], shown: [String: Int] = [:]) -> InAppCache {
        var cache = InAppCache(messages: messages)
        for m in messages { cache.pages[m.id] = InAppCachedPage(version: m.htmlVersion, light: false, file: "\(m.id).html") }
        cache.shown = shown
        return cache
    }

    // MARK: Decoding

    /// The answer of section 1 decodes, with null fields as nil and PostgreSQL's microsecond times readable.
    func testDecodesTheFetchAnswer() throws {
        let json = """
        {"messages":[{"id":"\(id1)","name":"Welcome","format":"modal","trigger":"app_open","trigger_name":null,
        "html_url":"https://x.test/v3.html","light_html_url":"https://x.test/v3.light.html","html_version":3,
        "assets":["https://cdn.example.com/hero.png"],"cap_per_device":2,"shown_count":1,"coach_target":null,
        "starts_at":"2026-11-19T10:00:00.123456+00:00","ends_at":null}],"allowed_origins":["https://api.example.com"]}
        """
        let list = try XCTUnwrap(InAppList.decode(Data(json.utf8)))
        XCTAssertEqual(list.allowedOrigins, ["https://api.example.com"])
        let m = try XCTUnwrap(list.messages.first)
        XCTAssertEqual(m.htmlVersion, 3)
        XCTAssertEqual(m.lightHtmlUrl, "https://x.test/v3.light.html")
        XCTAssertEqual(m.assets, ["https://cdn.example.com/hero.png"])
        XCTAssertEqual(m.capPerDevice, 2)
        XCTAssertNil(m.triggerName)
        let starts = try XCTUnwrap(InAppDates.parse(try XCTUnwrap(m.startsAt)))
        XCTAssertEqual(starts.timeIntervalSince1970, 1_795_082_400.123, accuracy: 0.001)
        XCTAssertNil(InAppList.decode(Data(#"{"messages":"no"}"#.utf8)))
    }

    /// Dates read with and without fractions; event times carry milliseconds.
    func testDates() {
        XCTAssertEqual(InAppDates.parse("2026-11-19T10:00:00Z")?.timeIntervalSince1970, 1_795_082_400)
        XCTAssertEqual(InAppDates.parse("2026-11-19T10:00:00.5+00:00")?.timeIntervalSince1970, 1_795_082_400.5)
        XCTAssertNil(InAppDates.parse("soon"))
        XCTAssertEqual(InAppDates.format(Date(timeIntervalSince1970: 1_795_082_400.25)), "2026-11-19T10:00:00.250Z")
    }

    // MARK: Cache

    /// The key is the lowercased message id and version, marked when light; a non-UUID id gets no file.
    func testCacheFileNames() {
        XCTAssertEqual(InAppPage.cacheFile(id: id1.uppercased(), version: 3, light: false), "\(id1).v3.html")
        XCTAssertEqual(InAppPage.cacheFile(id: id1, version: 3, light: true), "\(id1).v3.light.html")
        XCTAssertNil(InAppPage.cacheFile(id: "../../etc", version: 1, light: false))
    }

    /// Every occurrence becomes a data URI; a URL that extends another asset's URL is replaced whole.
    func testAssetsBecomeDataURIs() {
        let html = #"<img src="https://c.test/a.png"><img src="https://c.test/a.png?v=2"><i style="background:url(https://c.test/a.png)">"#
        let page = InAppPage.inline(html, assets: [
            "https://c.test/a.png": (Data([1, 2, 3]), "image/png"),
            "https://c.test/a.png?v=2": (Data([4]), "image/webp"),
        ])
        XCTAssertEqual(page, #"<img src="data:image/png;base64,AQID"><img src="data:image/webp;base64,BA=="><i style="background:url(data:image/png;base64,AQID)">"#)
    }

    /// A new answer drops pages of missing messages and older versions, and counts of missing messages.
    func testNewAnswerReplacesOldPages() {
        var cache = cached([message(id1, version: 1), message(id2)], shown: [id1: 1, id2: 2])
        let stale = InAppStore.apply(InAppList(messages: [message(id1, version: 2)], allowedOrigins: nil), to: &cache)
        XCTAssertEqual(stale, ["\(id1).html", "\(id2).html"])
        XCTAssertTrue(cache.pages.isEmpty)
        XCTAssertEqual(cache.shown, [id1: 1])
        XCTAssertEqual(cache.messages.map(\.htmlVersion), [2])
        XCTAssertEqual(cache.allowedOrigins, [])
    }

    /// A page is written only when the page and every asset downloaded; then its assets are inlined.
    func testCachesOnlyWhenEverythingDownloaded() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var failing: Set<String> = ["https://c.test/b.png"]
        let files = ["https://cdn.test/\(id1).html": #"<img src="https://c.test/a.png"><img src="https://c.test/b.png">"#,
                     "https://c.test/a.png": "A", "https://c.test/b.png": "B"]
        let store = InAppStore(folder: folder) { request in
            let url = request.url!.absoluteString
            guard !failing.contains(url), let body = files[url] else { return nil }
            let mime = url.hasSuffix(".png") ? "image/png" : "text/html"
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": mime])!)
        }
        let m = message(id1, version: 4, assets: ["https://c.test/a.png", "https://c.test/b.png"])
        let missing = await store.cache(m, slow: false)
        XCTAssertNil(missing)
        XCTAssertNil(store.readPage("\(id1).v4.html"))
        failing = []
        let page = await store.cache(m, slow: false)
        XCTAssertEqual(page, InAppCachedPage(version: 4, light: false, file: "\(id1).v4.html"))
        XCTAssertEqual(store.readPage("\(id1).v4.html"), #"<img src="data:image/png;base64,QQ=="><img src="data:image/png;base64,Qg==">"#)
    }

    // MARK: Slow phone

    /// Under 3 GB of memory is slow, and a slow phone takes the light page when there is one.
    func testSlowPhoneTakesTheLightPage() {
        let gb: UInt64 = 1024 * 1024 * 1024
        XCTAssertTrue(InAppPage.isSlowPhone(physicalMemory: 2 * gb))
        XCTAssertFalse(InAppPage.isSlowPhone(physicalMemory: 3 * gb))
        XCTAssertFalse(InAppPage.isSlowPhone(physicalMemory: 6 * gb))
        let both = message(id1, light: "https://cdn.test/light.html")
        XCTAssertEqual(InAppPage.pageURL(both, slow: true).url, "https://cdn.test/light.html")
        XCTAssertTrue(InAppPage.pageURL(both, slow: true).light)
        XCTAssertEqual(InAppPage.pageURL(both, slow: false).url, both.htmlUrl)
        XCTAssertFalse(InAppPage.pageURL(message(id1), slow: true).light)
    }

    // MARK: Page

    /// The CSP and bridge go right after `<head>` (with attributes too, not `<header>`), else at the very start.
    func testInsertsPolicyAndBridgeAfterHead() {
        let added = InAppPage.csp([]) + InAppPage.bridge(.init())
        XCTAssertEqual(InAppPage.prepare("<html><HEAD><title>t</title>", origins: [], values: .init()), "<html><HEAD>" + added + "<title>t</title>")
        XCTAssertEqual(InAppPage.prepare(#"<header></header><head lang="en">x"#, origins: [], values: .init()),
                       #"<header></header><head lang="en">"# + added + "x")
        XCTAssertEqual(InAppPage.prepare("<p>hi</p>", origins: [], values: .init()), added + "<p>hi</p>")
    }

    /// connect-src lists the allowed origins, or 'none'; an origin that could change the policy is dropped.
    func testPolicyConnectSources() {
        XCTAssertTrue(InAppPage.csp([]).contains("connect-src 'none'\">"))
        XCTAssertTrue(InAppPage.csp([]).hasPrefix(#"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; "#))
        XCTAssertEqual(InAppPage.connectSources(["https://api.example.com", "http://localhost:8000"]), "https://api.example.com http://localhost:8000")
        XCTAssertEqual(InAppPage.connectSources(["https://a.test; frame-src *", "https://a.test\"><x", "javascript:x", "https://a.test/path"]), "'none'")
    }

    /// The bridge carries insets, island, target and light, and posts to the `pushpilot` handler.
    func testBridgeValues() {
        let script = InAppPage.bridge(.init(insets: (59, 0, 34, 0), island: CGRect(x: 134, y: 11, width: 125, height: 37),
                                            target: nil, light: true))
        XCTAssertTrue(script.contains("insets:Object.freeze({top:59.0,right:0.0,bottom:34.0,left:0.0})"))
        XCTAssertTrue(script.contains("island:{x:134.0,y:11.0,width:125.0,height:37.0}"))
        XCTAssertTrue(script.contains("target:null"))
        XCTAssertTrue(script.contains(#"platform:"ios",light:true"#))
        XCTAssertTrue(script.contains("window.webkit.messageHandlers.pushpilot.postMessage(JSON.stringify({type:t"))
        XCTAssertTrue(script.hasPrefix("<script>") && script.hasSuffix("</script>"))
    }

    // MARK: Eligibility

    /// app_open takes the first app_open message in answer order; showInApp matches trigger_name only.
    func testTriggers() {
        let cache = cached([message(id1, trigger: "show_in_app", name: "checkout"), message(id2)])
        XCTAssertEqual(InAppRules.pick(cache, trigger: .appOpen, now: now) { _ in nil }?.message.id, id2)
        XCTAssertEqual(InAppRules.pick(cache, trigger: .named("checkout"), now: now) { _ in nil }?.message.id, id1)
        XCTAssertNil(InAppRules.pick(cache, trigger: .named("home"), now: now) { _ in nil })
        let order = cached([message(id1), message(id2)])
        XCTAssertEqual(InAppRules.pick(order, trigger: .appOpen, now: now) { _ in nil }?.message.id, id1)
    }

    /// Only a message whose current version is cached can show.
    func testNeedsTheCurrentPageCached() {
        var cache = cached([message(id1, version: 2)])
        cache.pages[id1] = InAppCachedPage(version: 1, light: false, file: "old")
        XCTAssertNil(InAppRules.pick(cache, trigger: .appOpen, now: now) { _ in nil })
        cache.pages[id1] = nil
        XCTAssertNil(InAppRules.pick(cache, trigger: .appOpen, now: now) { _ in nil })
    }

    /// The cap uses the larger of this device's count and the server's.
    func testCapUsesTheLargerCount() {
        let m = message(id1, cap: 2, shown: 1)
        XCTAssertNotNil(InAppRules.pick(cached([m], shown: [id1: 1]), trigger: .appOpen, now: now) { _ in nil })
        XCTAssertNil(InAppRules.pick(cached([m], shown: [id1: 2]), trigger: .appOpen, now: now) { _ in nil })
        XCTAssertNil(InAppRules.pick(cached([message(id1, cap: 2, shown: 2)]), trigger: .appOpen, now: now) { _ in nil })
        XCTAssertNotNil(InAppRules.pick(cached([message(id1)], shown: [id1: 99]), trigger: .appOpen, now: now) { _ in nil })
    }

    /// Dates are checked against the device clock; an unreadable date keeps the message hidden.
    func testDatesOnTheDeviceClock() {
        let before = "2027-01-15T07:59:59Z", after = "2027-01-15T08:00:01.000001+00:00" // now is 2027-01-15T08:00:00Z
        XCTAssertTrue(InAppRules.inDates(message(id1, starts: before, ends: after), now: now))
        XCTAssertFalse(InAppRules.inDates(message(id1, starts: after), now: now))
        XCTAssertFalse(InAppRules.inDates(message(id1, ends: before), now: now))
        XCTAssertFalse(InAppRules.inDates(message(id1, ends: "2027-01-15T08:00:00Z"), now: now))
        XCTAssertFalse(InAppRules.inDates(message(id1, starts: "yesterday"), now: now))
    }

    /// A coach mark shows only with its marked view on screen, whose frame becomes the target.
    func testCoachMarkNeedsItsView() {
        let frame = CGRect(x: 10, y: 700, width: 44, height: 44)
        let cache = cached([message(id1, format: "coach_mark", coach: "compose"), message(id2, format: "coach_mark")])
        XCTAssertNil(InAppRules.pick(cache, trigger: .appOpen, now: now) { _ in nil })
        let pick = InAppRules.pick(cache, trigger: .appOpen, now: now) { $0 == "compose" ? frame : nil }
        XCTAssertEqual(pick?.message.id, id1)
        XCTAssertEqual(pick?.target, frame)
        XCTAssertNil(InAppRules.pick(cached([message(id1)]), trigger: .appOpen, now: now) { _ in frame }?.target)
    }

    // MARK: Island

    /// A portrait iPhone with a 59 pt or larger top inset has an island; notched phones, landscape and iPads do not.
    func testIslandFrame() {
        XCTAssertEqual(InAppRules.island(topInset: 59, size: CGSize(width: 393, height: 852), isPhone: true),
                       CGRect(x: 134, y: 11, width: 125, height: 37))
        XCTAssertEqual(InAppRules.island(topInset: 62, size: CGSize(width: 402, height: 874), isPhone: true)?.minX, 138.5)
        XCTAssertNil(InAppRules.island(topInset: 47, size: CGSize(width: 390, height: 844), isPhone: true))
        XCTAssertNil(InAppRules.island(topInset: 59, size: CGSize(width: 852, height: 393), isPhone: true))
        XCTAssertNil(InAppRules.island(topInset: 59, size: CGSize(width: 820, height: 1180), isPhone: false))
    }

    // MARK: Bridge commands

    /// The page's JSON string becomes a command; refused links, other shapes and unknown types do nothing.
    func testBridgeCommands() {
        XCTAssertEqual(InAppRules.command(#"{"type":"close","value":""}"#), .close)
        XCTAssertEqual(InAppRules.command(#"{"type":"open","value":"myapp://cart"}"#), .open(URL(string: "myapp://cart")!))
        XCTAssertEqual(InAppRules.command(#"{"type":"open","value":"https://example.com/x"}"#), .open(URL(string: "https://example.com/x")!))
        for refused in ["javascript:alert(1)", "JavaScript:alert(1)", "data:text/html,x", "file:///etc/hosts", "blob:https://a/b", "/relative", ""] {
            XCTAssertNil(InAppRules.command(#"{"type":"open","value":"\#(refused)"}"#), refused)
        }
        XCTAssertEqual(InAppRules.command(#"{"type":"haptic","value":"success"}"#), .haptic("success"))
        XCTAssertEqual(InAppRules.command(#"{"type":"track","value":"buy"}"#), .track("buy"))
        XCTAssertNil(InAppRules.command(#"{"type":"eval","value":"x"}"#))
        XCTAssertNil(InAppRules.command(["type": "close"]))
        XCTAssertNil(InAppRules.command("not json"))
    }

    // MARK: Events

    /// `dismissed` only when the showing closes after being shown with no accepted `track`.
    func testDismissedOnlyWithoutTrack() {
        var plain = InAppShowing()
        XCTAssertNil(plain.closed(at: now), "never shown")
        XCTAssertEqual(plain.shown(at: now), .init(type: "shown", buttonId: nil, at: now))
        XCTAssertNil(plain.shown(at: now + 1), "shown once")
        XCTAssertEqual(plain.closed(at: now + 2), .init(type: "dismissed", buttonId: nil, at: now + 2))

        var tracked = InAppShowing()
        _ = tracked.shown(at: now)
        XCTAssertEqual(tracked.track("buy", at: now + 1), .init(type: "clicked", buttonId: "buy", at: now + 1))
        XCTAssertNil(tracked.closed(at: now + 2))

        var refused = InAppShowing()
        _ = refused.shown(at: now)
        XCTAssertNil(refused.track(String(repeating: "x", count: 65), at: now))
        XCTAssertNil(refused.track("", at: now))
        XCTAssertNotNil(refused.track(String(repeating: "x", count: 64), at: now + 1))
        var long = InAppShowing()
        _ = long.shown(at: now)
        XCTAssertNil(long.track(String(repeating: "é", count: 33), at: now), "66 bytes")
        XCTAssertNotNil(long.closed(at: now + 1))
    }

    /// In-app events are queued on disk and sent in batches of 100 to in-app/events; a failure resends them.
    func testEngineSendsInAppEvents() throws {
        let storage = FakeStorage(), network = FakeNetwork(), clock = FakeClock()
        let engine = try Engine(sdkKey: "pk_test", baseUrl: PushPilot.defaultBaseUrl, storage: storage, network: network,
                                clock: clock, device: FakeDevice(), jitter: { 1 })
        for n in 0..<101 { engine.trackInApp("shown", messageId: id1, buttonId: nil, at: now + Double(n)) }
        engine.trackInApp("clicked", messageId: id1, buttonId: "buy", at: now.addingTimeInterval(0.5))
        XCTAssertEqual(storage.state?.inAppEvents?.count, 102)
        clock.advance(Engine.coalesceDelay)
        let call = try XCTUnwrap(network.open.first)
        XCTAssertEqual(call.url, "https://pushpilot.ai/api/sdk/v1/in-app/events/")
        guard case .array(let first)? = call.body["events"] else { return XCTFail("no events") }
        XCTAssertEqual(first.count, 100)
        XCTAssertEqual(first.first, .object(["message_id": .string(id1), "installation_id": .string(engine.installationId),
                                             "type": .string("shown"), "at": .string("2027-01-15T08:00:00.000Z")]))
        network.fail()
        clock.advance(1)
        XCTAssertEqual(network.open.first?.body["events"], call.body["events"], "same batch after a failure")
        network.reply()
        guard case .array(let rest)? = network.open.first?.body["events"] else { return XCTFail("no second batch") }
        XCTAssertEqual(rest.count, 2)
        XCTAssertEqual(rest.last, .object(["message_id": .string(id1), "installation_id": .string(engine.installationId),
                                           "type": .string("clicked"), "button_id": .string("buy"), "at": .string("2027-01-15T08:00:00.500Z")]))
        network.reply()
        XCTAssertEqual(storage.state?.inAppEvents, [])
    }

    #if canImport(UIKit)
    /// A marked view counts as on screen only in a window, shown, and wholly inside it.
    @MainActor
    func testVisibleFrame() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        let parent = UIView(frame: CGRect(x: 0, y: 100, width: 390, height: 200))
        let view = UIView(frame: CGRect(x: 20, y: 30, width: 44, height: 44))
        parent.addSubview(view)
        XCTAssertNil(InAppController.visibleFrame(view), "not in a window")
        window.addSubview(parent)
        XCTAssertEqual(InAppController.visibleFrame(view), CGRect(x: 20, y: 130, width: 44, height: 44))
        parent.alpha = 0
        XCTAssertNil(InAppController.visibleFrame(view), "transparent ancestor")
        parent.alpha = 1
        view.frame.origin.y = 800
        XCTAssertNil(InAppController.visibleFrame(view), "off screen")
    }
    #endif
}
