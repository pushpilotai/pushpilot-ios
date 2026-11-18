import XCTest
@testable import PushPilot

/// `PushPilot.status`: the installation, the reported live flags and the last sync, without any token.
final class StatusTests: XCTestCase {
    let storage = FakeStorage()
    let network = FakeNetwork()
    let clock = FakeClock()
    let device = FakeDevice()

    /// An engine on the fakes with jitter fixed at 1.
    func makeEngine() throws -> Engine {
        try Engine(sdkKey: "pk_test", baseUrl: PushPilot.defaultBaseUrl, storage: storage, network: network,
                   clock: clock, device: device, jitter: { 1 })
    }

    /// Before any sync the status has the id and no live flags; after one it has the result and the reported token.
    func testStatusFollowsWhatTheServerAccepted() throws {
        let engine = try makeEngine()
        var status = engine.status
        XCTAssertEqual(status.installationId, engine.installationId)
        XCTAssertNil(status.liveSupported)
        XCTAssertFalse(status.liveStartTokenReported)
        XCTAssertNil(status.lastSyncResult)

        engine.setLive(["supported": .bool(true), "enabled": .bool(true), "app_group": .bool(false), "start_token": .string("c0ffee")])
        clock.advance(Engine.coalesceDelay)
        XCTAssertFalse(engine.status.liveStartTokenReported, "not reported until the server accepts it")
        network.reply(200)
        status = engine.status
        XCTAssertEqual(status.liveSupported, true)
        XCTAssertEqual(status.liveEnabled, true)
        XCTAssertEqual(status.liveAppGroup, false)
        XCTAssertTrue(status.liveStartTokenReported)
        XCTAssertEqual(status.lastSyncResult, "register: OK (HTTP 200)")
        XCTAssertNotNil(status.lastSyncAt)
        XCTAssertFalse(String(describing: status).contains("c0ffee"), "the status never holds a token")
    }

    /// A failed or rejected sync shows in the result.
    func testFailedSyncShowsInTheResult() throws {
        let engine = try makeEngine()
        engine.setTopics(["news"])
        clock.advance(Engine.coalesceDelay)
        network.fail()
        XCTAssertTrue(engine.status.lastSyncResult?.hasPrefix("register: failed") == true)
        clock.advance(1)
        network.reply(401)
        XCTAssertEqual(engine.status.lastSyncResult, "register: rejected (HTTP 401)")
    }
}
