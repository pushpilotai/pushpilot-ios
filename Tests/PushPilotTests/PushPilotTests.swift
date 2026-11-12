import UserNotifications
import XCTest
@testable import PushPilot

final class PushPilotTests: XCTestCase {
    /// Calls before initialize are queued and applied in order once it runs; a second initialize is ignored.
    func testCallsBeforeInitializeAreQueuedAndInitIsIdempotent() throws {
        let storage = FakeStorage(), network = FakeNetwork(), clock = FakeClock()
        var created = 0
        var engine: Engine?
        PushPilot.makeEngine = { key, url in
            created += 1
            let made = try Engine(sdkKey: key, baseUrl: url, storage: storage, network: network, clock: clock, device: FakeDevice())
            engine = made
            return made
        }
        PushPilot.setPushToken(tok1)
        PushPilot.setExternalUserId("user-9")
        PushPilot.queue.sync {}
        XCTAssertNil(engine)
        PushPilot.initialize(sdkKey: "pk_test")
        PushPilot.initialize(sdkKey: "other")
        PushPilot.queue.sync {}
        XCTAssertEqual(created, 1)
        XCTAssertEqual(engine?.state.token, hex1)
        XCTAssertEqual(engine?.state.externalUserId, "user-9")
        PushPilot.queue.sync { clock.advance(Engine.coalesceDelay) }
        XCTAssertEqual(network.all.count, 1)
        XCTAssertEqual(network.all.first?.sdkKey, "pk_test")
    }

    /// The real state file round-trips, and its folder stays excluded from backup across atomic rewrites.
    func testStateFileIsExcludedFromBackup() throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PushPilot")
        try? FileManager.default.removeItem(at: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = DeviceStorage()
        XCTAssertNil(try storage.readState())
        try storage.writeState(State(token: "tok-1"))
        try storage.writeState(State(token: "tok-2"))
        XCTAssertEqual(try storage.readState()?.token, "tok-2")
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// Only pushes the server marked with source = pushpilot are claimed.
    func testHandleMessage() {
        XCTAssertTrue(PushPilot.handleMessage(["source": "pushpilot", "aps": ["alert": "hi"]]))
        XCTAssertFalse(PushPilot.handleMessage(["source": "other"]))
        XCTAssertFalse(PushPilot.handleMessage(["aps": ["alert": "hi"]]))
    }

    /// A payload v2 push as iOS hands it to the app.
    let push: [AnyHashable: Any] = [
        "aps": ["alert": ["title": "नमस्ते", "body": "مرحبا"], "mutable-content": 1],
        "source": "pushpilot",
        "notification_id": "n-1",
        "url": "myapp://orders/42",
        "buttons": [
            ["id": "track", "label": "Track", "url": "https://example.com/track"],
            ["id": "later", "label": "Later"],
        ],
        "data": ["order_id": "42"],
    ]

    /// Body tap: no button, the push's url. Button with url: its id and url. Button without: its id, no link.
    func testTapDecision() throws {
        let body = try XCTUnwrap(Tap(userInfo: push, action: UNNotificationDefaultActionIdentifier))
        XCTAssertEqual([body.notificationId, body.buttonId, body.url?.absoluteString], ["n-1", nil, "myapp://orders/42"])
        let track = try XCTUnwrap(Tap(userInfo: push, action: "track"))
        XCTAssertEqual([track.notificationId, track.buttonId, track.url?.absoluteString], ["n-1", "track", "https://example.com/track"])
        let later = try XCTUnwrap(Tap(userInfo: push, action: "later"))
        XCTAssertEqual([later.notificationId, later.buttonId, later.url?.absoluteString], ["n-1", "later", nil])
        XCTAssertNil(Tap(userInfo: push, action: UNNotificationDismissActionIdentifier), "a dismissal is not an event")
        let bare = try XCTUnwrap(Tap(userInfo: ["source": "pushpilot", "url": ""], action: UNNotificationDefaultActionIdentifier))
        XCTAssertNil(bare.notificationId)
        XCTAssertNil(bare.url)
    }

    /// Links go to the app's handler when one is set, otherwise to the system; other pushes are left alone.
    func testLinkHandlerOverridesTheSystem() {
        var systemOpened: [URL] = []
        let original = PushPilot.systemOpen
        defer { PushPilot.systemOpen = original; PushPilot.setLinkHandler(nil) }
        PushPilot.systemOpen = { systemOpened.append($0) }

        func tapAndWait(_ userInfo: [AnyHashable: Any], _ action: String) -> Bool {
            let handled = PushPilot.handleTap(userInfo: userInfo, action: action)
            PushPilot.queue.sync {}
            let mainDone = expectation(description: "main queue drained")
            DispatchQueue.main.async { mainDone.fulfill() }
            wait(for: [mainDone], timeout: 2)
            return handled
        }

        XCTAssertTrue(tapAndWait(push, UNNotificationDefaultActionIdentifier))
        XCTAssertEqual(systemOpened, [URL(string: "myapp://orders/42")!])

        var handled: [URL] = []
        PushPilot.setLinkHandler { handled.append($0) }
        XCTAssertTrue(tapAndWait(push, "track"))
        XCTAssertEqual(handled, [URL(string: "https://example.com/track")!])
        XCTAssertEqual(systemOpened.count, 1, "the handler replaces the system")

        XCTAssertTrue(tapAndWait(push, "later"), "a button without a link opens nothing")
        XCTAssertFalse(tapAndWait(["source": "other", "url": "https://x.io"], UNNotificationDefaultActionIdentifier))
        XCTAssertEqual(handled.count, 1)
    }

    /// OS authorisation states map to the server's four values.
    func testPermissionMapping() {
        XCTAssertEqual(SystemDeviceInfo.permission(.authorized), "granted")
        XCTAssertEqual(SystemDeviceInfo.permission(.ephemeral), "granted")
        XCTAssertEqual(SystemDeviceInfo.permission(.denied), "denied")
        XCTAssertEqual(SystemDeviceInfo.permission(.provisional), "provisional")
        XCTAssertEqual(SystemDeviceInfo.permission(.notDetermined), "unknown")
    }

    /// Automatic fields have the server's names and formats.
    func testAutomaticFields() {
        let fields = SystemDeviceInfo.fields(permission: "unknown")
        XCTAssertEqual(Set(fields.keys), ["notification_permission", "os_version", "app_version", "sdk_version",
                                          "device_model", "locale", "timezone"])
        XCTAssertEqual(fields["sdk_version"], .string(PushPilot.sdkVersion))
        XCTAssertEqual(SystemDeviceInfo.bcp47(Locale(identifier: "en_US")), "en-US")
        XCTAssertEqual(SystemDeviceInfo.bcp47(Locale(identifier: "pt_BR")), "pt-BR")
        XCTAssertEqual(fields["timezone"], .string(TimeZone.current.identifier))
        XCTAssertFalse(SystemDeviceInfo.modelIdentifier().isEmpty)
    }
}
