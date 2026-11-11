import XCTest
@testable import PushPilot

final class EngineTests: XCTestCase {
    let storage = FakeStorage()
    let network = FakeNetwork()
    let clock = FakeClock()
    let device = FakeDevice()
    let base = "https://pushpilot.ai/api/sdk/v1"

    /// An engine on the fakes with jitter fixed at 1, so backoff delays are exact.
    func makeEngine() throws -> Engine {
        try Engine(sdkKey: "pk_test", baseUrl: PushPilot.defaultBaseUrl, storage: storage, network: network,
                   clock: clock, device: device, jitter: { 1 })
    }

    /// Runs the coalescing delay so the pending sync goes out.
    func tick() { clock.advance(Engine.coalesceDelay) }

    /// The first sync registers with the token, the automatic fields and the SDK key; the id is stored.
    func testFirstSyncRegistersWithEveryField() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        let call = try XCTUnwrap(network.open.first)
        XCTAssertEqual(call.url, "\(base)/register/")
        XCTAssertEqual(call.sdkKey, "pk_test")
        var expected = FakeDevice.fields("granted")
        expected["installation_id"] = .string(engine.installationId)
        expected["token"] = .string("tok-1")
        expected["external_user_id"] = .null
        XCTAssertEqual(call.body, expected)
        XCTAssertEqual(storage.id, engine.installationId)
        XCTAssertNotNil(UUID(uuidString: engine.installationId))
    }

    /// A Firebase Installation ID (22 base64url characters) is sent unchanged in `token`, and does not
    /// replace PushPilot's own installation id.
    func testFirebaseInstallationIdIsSentUnchangedAsToken() throws {
        let engine = try makeEngine()
        let fid = "cR_7xq-5Td2bLm9KpQz0aW"
        XCTAssertEqual(fid.count, 22)
        engine.setPushToken(fid)
        tick()
        XCTAssertEqual(network.open.first?.body["token"], .string(fid))
        XCTAssertEqual(network.open.first?.body["installation_id"], .string(engine.installationId))
    }

    /// Later changes go to sync with the full state, including topics and attributes.
    func testLaterChangesSyncTheFullState() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        network.reply()
        engine.setExternalUserId(" user-9 ")
        engine.setTopics(["sale", "news", "sale"])
        engine.setAttributes(["plan": "pro"])
        tick()
        let call = try XCTUnwrap(network.open.first)
        XCTAssertEqual(call.url, "\(base)/sync/")
        XCTAssertEqual(call.body["token"], .string("tok-1"))
        XCTAssertEqual(call.body["external_user_id"], .string("user-9"))
        XCTAssertEqual(call.body["topics"], .array([.string("news"), .string("sale")]))
        XCTAssertEqual(call.body["attributes"], .object(["plan": .string("pro")]))
    }

    /// Initialisation registers the installation at once with a null token; the token follows in a sync.
    func testRegistersAtInitWithoutAToken() throws {
        let engine = try makeEngine()
        engine.requestSync()
        tick()
        XCTAssertEqual(network.open.first?.url, "\(base)/register/")
        XCTAssertEqual(network.open.first?.body["token"], .null)
        network.reply()
        engine.setPushToken("tok-1")
        tick()
        XCTAssertEqual(network.open.first?.url, "\(base)/sync/")
        XCTAssertEqual(network.open.first?.body["token"], .string("tok-1"))
    }

    /// An unchanged state is not resent within 24 hours, and is resent at launch or foreground after that.
    func testUnchangedStateIsResentOnlyAfter24Hours() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        network.reply()
        clock.advance(Engine.staleAfter - 10)
        engine.requestSync()
        tick()
        XCTAssertEqual(network.all.count, 1)
        clock.advance(10)
        engine.requestSync()
        tick()
        XCTAssertEqual(network.all.count, 2)
        XCTAssertEqual(network.open.first?.url, "\(base)/sync/")
    }

    /// A permission change found at foreground is a state change and is sent at once.
    func testPermissionChangeIsSent() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        network.reply()
        device.permission = "denied"
        engine.requestSync()
        tick()
        XCTAssertEqual(network.open.first?.body["notification_permission"], .string("denied"))
    }

    /// Rapid changes become one request; a change during a request is sent after it finishes.
    func testRapidChangesAreCoalesced() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        engine.setExternalUserId("user-9")
        engine.setTopics(["news"])
        tick()
        XCTAssertEqual(network.all.count, 1)
        engine.setAttributes(["plan": "pro"])
        tick()
        XCTAssertEqual(network.all.count, 1, "waits for the open request")
        network.reply()
        tick()
        XCTAssertEqual(network.all.count, 2)
        XCTAssertEqual(network.open.first?.body["attributes"], .object(["plan": .string("pro")]))
    }

    /// Failures back off 1, 2, 4 … seconds up to 5 minutes, and a success resets the backoff.
    func testFailuresBackOffExponentiallyToFiveMinutes() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            network.reply(503)
            let delay = try XCTUnwrap(clock.nextDelay)
            delays.append(delay)
            clock.advance(delay)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 32, 64, 128, 256, 300])
        network.fail()
        XCTAssertEqual(clock.nextDelay, 300)
        clock.advance(300)
        network.reply()
        engine.setTopics(["news"])
        tick()
        network.fail()
        XCTAssertEqual(clock.nextDelay, 1)
    }

    /// Jitter stretches each delay but never past 5 minutes.
    func testJitterIsCappedAtFiveMinutes() throws {
        let engine = try Engine(sdkKey: "k", baseUrl: PushPilot.defaultBaseUrl, storage: storage, network: network,
                                clock: clock, device: device, jitter: { 1.25 })
        engine.setPushToken("tok-1")
        tick()
        network.reply(500)
        XCTAssertEqual(clock.nextDelay, 1.25)
        for _ in 0..<9 { clock.advance(clock.nextDelay!); network.reply(500) }
        XCTAssertEqual(clock.nextDelay, 300)
    }

    /// A 429 waits at least Retry-After, even when backoff would be shorter.
    func testTooManyRequestsWaitsForRetryAfter() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        network.reply(429, retryAfter: 30)
        clock.advance(29)
        XCTAssertTrue(network.open.isEmpty)
        clock.advance(1)
        XCTAssertEqual(network.open.count, 1)
    }

    /// Other 4xx answers are not retried, and the same state is not resent until it changes.
    func testOtherClientErrorsAreNotRetried() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        network.reply(401)
        XCTAssertNil(clock.nextDelay)
        engine.requestSync()
        tick()
        XCTAssertEqual(network.all.count, 1)
        engine.setTopics(["news"])
        tick()
        XCTAssertEqual(network.all.count, 2)
    }

    /// A different installation id in the reply replaces the stored one and is used from then on.
    func testReplacementInstallationIdIsAdopted() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        tick()
        let replacement = "0c8a4c56-2d1e-4b7e-9d1a-3f4b5c6d7e8f"
        network.reply(json: #"{"installation_id":"\#(replacement.uppercased())","throttled":false,"warnings":["x"]}"#)
        XCTAssertEqual(engine.installationId, replacement)
        XCTAssertEqual(storage.id, replacement)
        engine.setTopics(["news"])
        tick()
        XCTAssertEqual(network.open.first?.url, "\(base)/sync/")
        XCTAssertEqual(network.open.first?.body["installation_id"], .string(replacement))
    }

    /// Logout sends a null external user id to sync and keeps the token and installation.
    func testLogoutClearsOnlyTheExternalUserId() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        engine.setExternalUserId("user-9")
        tick()
        network.reply()
        let id = engine.installationId
        engine.logout()
        tick()
        let call = try XCTUnwrap(network.open.first)
        XCTAssertEqual(call.url, "\(base)/sync/")
        XCTAssertEqual(call.body["external_user_id"], .null)
        XCTAssertEqual(call.body["token"], .string("tok-1"))
        XCTAssertEqual(call.body["installation_id"], .string(id))
    }

    /// Forget deletes the old installation (retrying until answered), clears state, and registers the
    /// new id only after a setter call.
    func testForgetDeletesTheInstallationAndClearsState() throws {
        let engine = try makeEngine()
        engine.setPushToken("tok-1")
        engine.setExternalUserId("user-9")
        tick()
        network.reply()
        let old = engine.installationId
        engine.forget()
        XCTAssertNotEqual(engine.installationId, old)
        XCTAssertEqual(storage.id, engine.installationId)
        XCTAssertEqual(engine.state, State(pendingForgets: [old]))
        tick()
        XCTAssertEqual(network.open.first?.url, "\(base)/forget/")
        XCTAssertEqual(network.open.first?.body, ["installation_id": .string(old)])
        network.fail()
        clock.advance(1)
        XCTAssertEqual(network.open.first?.url, "\(base)/forget/")
        network.reply(204)
        XCTAssertEqual(engine.state, State())
        XCTAssertTrue(network.open.isEmpty, "the new id waits for a setter or the next launch")
        engine.requestSync()
        tick()
        XCTAssertTrue(network.open.isEmpty, "becoming active is not a setter")
        engine.setPushToken("tok-2")
        tick()
        XCTAssertEqual(network.open.first?.url, "\(base)/register/")
        XCTAssertEqual(network.open.first?.body["installation_id"], .string(engine.installationId))
    }

    /// After forget, the next launch registers the new id even without a setter call.
    func testNextLaunchAfterForgetRegistersTheNewId() throws {
        let engine = try makeEngine()
        engine.forget()
        let later = FakeClock()
        let relaunched = try Engine(sdkKey: "pk_test", baseUrl: PushPilot.defaultBaseUrl, storage: storage,
                                    network: network, clock: later, device: device)
        relaunched.requestSync()
        later.advance(Engine.coalesceDelay)
        XCTAssertEqual(network.open.first?.url, "\(base)/forget/")
        network.reply(204)
        XCTAssertEqual(network.open.first?.url, "\(base)/register/")
        XCTAssertEqual(network.open.first?.body["installation_id"], .string(engine.installationId))
        XCTAssertEqual(network.open.first?.body["token"], .null)
    }

    /// State and the pending forget survive app termination, so the next launch sends them.
    func testPendingWorkSurvivesRestart() throws {
        let first = try makeEngine()
        first.setPushToken("tok-1")
        first.forget()
        first.setPushToken("tok-2")
        // The app is killed before anything is sent; the next launch reads the same storage.
        let later = FakeClock()
        let second = try Engine(sdkKey: "pk_test", baseUrl: PushPilot.defaultBaseUrl, storage: storage,
                                network: network, clock: later, device: device)
        XCTAssertEqual(second.installationId, first.installationId)
        second.requestSync()
        later.advance(Engine.coalesceDelay)
        XCTAssertEqual(network.all.map(\.url), ["\(base)/forget/"])
        network.reply(204)
        XCTAssertEqual(network.open.first?.url, "\(base)/register/")
        XCTAssertEqual(network.open.first?.body["token"], .string("tok-2"))
    }

    /// Attribute values are converted by type; nil removes, unsupported types are skipped.
    func testAttributeConversion() throws {
        let engine = try makeEngine()
        let date = Date(timeIntervalSince1970: 0)
        engine.setAttributes(["s": "x", "i": 3, "d": 1.5, "b": true, "t": date, "gone": nil, "bad": [1]])
        XCTAssertEqual(engine.state.attributes, [
            "s": .string("x"), "i": .number(3), "d": .number(1.5), "b": .bool(true),
            "t": .string("1970-01-01T00:00:00Z"), "gone": .null,
        ])
        engine.setAttributes(["s": nil, "i": 4])
        XCTAssertEqual(engine.state.attributes["s"], .null)
        XCTAssertEqual(engine.state.attributes["i"], .number(4))
    }

    /// Values the server would reject are ignored locally so they cannot block every later sync.
    func testInvalidValuesAreIgnored() throws {
        let engine = try makeEngine()
        engine.setExternalUserId("user-9")
        engine.setExternalUserId("  ")
        engine.setExternalUserId(String(repeating: "x", count: 256))
        XCTAssertEqual(engine.state.externalUserId, "user-9")
        engine.setPushToken("tok")
        engine.setPushToken("")
        XCTAssertNil(engine.state.token)
    }

    /// Invalid topic names are dropped and the valid ones kept, de-duplicated, sorted and capped at 100.
    func testInvalidTopicNamesAreDropped() throws {
        let engine = try makeEngine()
        engine.setTopics(["sale", "bad topic", "", "news", "sale", String(repeating: "x", count: 256), "café"])
        XCTAssertEqual(engine.state.topics, ["news", "sale"])
        engine.setTopics(["bad topic"])
        XCTAssertEqual(engine.state.topics, [], "all invalid means no topics")
        let many = (0..<150).map { String(format: "t%03d", $0) }
        engine.setTopics(many.reversed())
        XCTAssertEqual(engine.state.topics, Array(many.prefix(100)))
    }

    /// A base URL with a path keeps it; endpoints always end with a slash.
    func testBaseUrlWithPath() throws {
        let engine = try Engine(sdkKey: "k", baseUrl: URL(string: "https://push.example.com/pp")!, storage: storage,
                                network: network, clock: clock, device: device)
        engine.setPushToken("tok-1")
        tick()
        XCTAssertEqual(network.open.first?.url, "https://push.example.com/pp/api/sdk/v1/register/")
    }
}
