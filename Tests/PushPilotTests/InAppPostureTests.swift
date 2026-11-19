import XCTest
@testable import PushPilot
#if canImport(WebKit)
import WebKit
#endif

/// Posture (IN-APP-SDK.md section 9) and the bridge script running in a real web view.
final class InAppPostureTests: XCTestCase {
    /// The stub reports `flat` with the window size, as JSON the page can read.
    func testStubIsFlatWithTheWindowSize() {
        let posture = FlatPostureSource().posture(windowSize: CGSize(width: 393, height: 852))
        XCTAssertEqual(posture, InAppPosture(state: "flat", width: 393, height: 852))
        XCTAssertEqual(posture.json, #"{"state":"flat","screen":{"width":393.0,"height":852.0}}"#)
        XCTAssertEqual(InAppPosture(state: "\"};alert(1)", width: .nan, height: 1).json,
                       #"{"state":"flat","screen":{"width":0,"height":1.0}}"#)
        XCTAssertEqual(InAppPosture(state: "half_open", width: 1, height: 2).json, #"{"state":"half_open","screen":{"width":1.0,"height":2.0}}"#)
    }

    /// The bridge carries the starting posture; a change runs `_posture` with the new one.
    func testBridgeCarriesPosture() {
        let posture = InAppPosture(state: "flat", width: 390, height: 844)
        XCTAssertTrue(InAppPage.bridge(.init(posture: posture)).contains("cur=fz(\(posture.json))"))
        XCTAssertEqual(InAppPage.postureUpdate(posture), "window.pushpilot&&window.pushpilot._posture(\(posture.json));")
    }

    #if canImport(WebKit)
    /// Collects what the page posts to the `pushpilot` handler.
    final class Inbox: NSObject, WKScriptMessageHandler {
        var bodies: [String] = []
        /// Keeps each message body.
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String { bodies.append(body) }
        }
    }

    /// Waits for the web view to finish loading.
    final class Loaded: NSObject, WKNavigationDelegate {
        let done: XCTestExpectation
        /// Fulfils `done` on load.
        init(_ done: XCTestExpectation) { self.done = done }
        /// The page loaded.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done.fulfill() }
    }

    /// Runs `script` in the page and returns its result.
    @MainActor
    func run(_ webView: WKWebView, _ script: String) async throws -> Any? {
        try await webView.evaluateJavaScript(script)
    }

    /// In WebKit the bridge defines a frozen `window.pushpilot` before page scripts, posts JSON strings, and
    /// `_posture` updates `posture`, calls `onPosture` callbacks and fires `pushpilotposture`.
    @MainActor
    func testBridgeRunsInWebKit() async throws {
        let inbox = Inbox()
        let config = WKWebViewConfiguration()
        config.userContentController.add(inbox, name: "pushpilot")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let loaded = Loaded(expectation(description: "loaded"))
        webView.navigationDelegate = loaded
        let values = InAppPage.Values(insets: (47, 0, 34, 0), light: true, posture: InAppPosture(state: "flat", width: 390, height: 844))
        let page = """
        <html><head><script>window.early = typeof window.pushpilot; window.seen = [];
        pushpilot.onPosture(function (p) { seen.push(p.state + ":" + p.screen.width); });
        addEventListener("pushpilotposture", function (e) { seen.push("event:" + e.detail.screen.height); });</script></head><body></body></html>
        """
        webView.loadHTMLString(InAppPage.prepare(page, origins: [], values: values), baseURL: InAppPage.baseURL)
        await fulfillment(of: [loaded.done], timeout: 10)

        let early = try await run(webView, "window.early") as? String
        XCTAssertEqual(early, "object")
        let top = try await run(webView, "pushpilot.insets.top") as? Double
        XCTAssertEqual(top, 47)
        let frozen = try await run(webView, #"pushpilot.close = 1; pushpilot.posture.state = "x"; typeof pushpilot.close + pushpilot.posture.state"#) as? String
        XCTAssertEqual(frozen, "functionflat")
        _ = try await run(webView, InAppPage.postureUpdate(InAppPosture(state: "flat", width: 844, height: 390)))
        let seen = try await run(webView, #"seen.join(",") + "|" + pushpilot.posture.screen.width"#) as? String
        XCTAssertEqual(seen, "flat:390,flat:844,event:390|844")
        _ = try await run(webView, #"pushpilot.track("buy"); pushpilot.close(); 0"#)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(inbox.bodies.compactMap(InAppRules.command), [.track("buy"), .close])
    }
    #endif
}
