import UserNotifications
import XCTest
@testable import PushPilot

final class PushPilotTests: XCTestCase {
    let storage = FakeStorage(), network = FakeNetwork(), clock = FakeClock()
    /// Holds the saved configuration, as config.json does on a device.
    let saved = FakeStorage()
    var created = 0
    var engine: Engine?
    var systemOpened: [URL] = []
    let originalOpen = PushPilot.systemOpen

    /// Each test starts as a fresh process with fake storage, network and link opening.
    override func setUp() {
        PushPilot.resetForTesting()
        PushPilot.configStorage = saved
        PushPilot.systemOpen = { [unowned self] in systemOpened.append($0) }
        PushPilot.makeEngine = { [unowned self] key, url in
            created += 1
            let made = try Engine(sdkKey: key, baseUrl: url, storage: storage, network: network, clock: clock, device: FakeDevice())
            engine = made
            return made
        }
    }

    /// Puts back the real link opener and storage for other test classes.
    override func tearDown() {
        PushPilot.resetForTesting()
        PushPilot.systemOpen = originalOpen
        PushPilot.configStorage = DeviceStorage()
    }

    /// Waits until the SDK queue and then the main queue have run everything queued so far.
    func drain() {
        PushPilot.queue.sync {}
        let mainDone = expectation(description: "main queue drained")
        DispatchQueue.main.async { mainDone.fulfill() }
        wait(for: [mainDone], timeout: 2)
    }

    /// Calls before initialize are queued and applied in order once it runs; a second initialize is ignored.
    func testCallsBeforeInitializeAreQueuedAndInitIsIdempotent() throws {
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
        XCTAssertEqual(saved.config, SavedConfig(sdkKey: "pk_test", baseUrl: PushPilot.defaultBaseUrl))
    }

    /// Without initialize, the first SDK call starts from the saved values; a later initialize wins and is saved.
    func testStartsFromSavedConfigUntilInitialize() throws {
        let selfHosted = URL(string: "https://push.example.com")!
        saved.config = SavedConfig(sdkKey: "pk_saved", baseUrl: selfHosted)
        PushPilot.setPushToken(tok1)
        PushPilot.queue.sync { clock.advance(Engine.coalesceDelay) }
        XCTAssertEqual(created, 1)
        XCTAssertEqual(network.all.last?.sdkKey, "pk_saved")
        XCTAssertEqual(network.all.last?.url.hasPrefix("https://push.example.com/api/sdk/v1/"), true)
        PushPilot.queue.sync { network.reply() }

        PushPilot.initialize(sdkKey: "pk_new")
        PushPilot.setExternalUserId("user-1")
        PushPilot.queue.sync { clock.advance(Engine.coalesceDelay) }
        XCTAssertEqual(created, 1, "the running engine is kept, with the new values")
        XCTAssertEqual(network.all.last?.sdkKey, "pk_new")
        XCTAssertEqual(network.all.last?.url.hasPrefix("https://pushpilot.ai/api/sdk/v1/"), true)
        XCTAssertEqual(saved.config, SavedConfig(sdkKey: "pk_new", baseUrl: PushPilot.defaultBaseUrl))

        PushPilot.initialize(sdkKey: "pk_ignored")
        PushPilot.queue.sync {}
        XCTAssertEqual(saved.config?.sdkKey, "pk_new", "a second initialize is still ignored")
    }

    /// forget keeps the saved key: it is the app's setting, and a later tap must still be able to start the SDK.
    func testForgetKeepsSavedConfig() {
        PushPilot.initialize(sdkKey: "pk_test")
        PushPilot.forget()
        PushPilot.queue.sync {}
        XCTAssertEqual(saved.config?.sdkKey, "pk_test")
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
    func push(_ id: String = "n-1") -> [AnyHashable: Any] { [
        "aps": ["alert": ["title": "नमस्ते", "body": "مرحبا"], "mutable-content": 1],
        "source": "pushpilot",
        "notification_id": id,
        "url": "myapp://orders/42",
        "buttons": [
            ["id": "track", "label": "Track", "url": "https://example.com/track"],
            ["id": "later", "label": "Later"],
        ],
        "data": ["order_id": "42"],
    ] }

    /// Body tap: no button, the push's url. Button with url: its id and url. Button without: its id, no link.
    func testTapDecision() throws {
        let body = try XCTUnwrap(Tap(userInfo: push(), action: UNNotificationDefaultActionIdentifier))
        XCTAssertEqual([body.notificationId, body.buttonId, body.url?.absoluteString], ["n-1", nil, "myapp://orders/42"])
        let track = try XCTUnwrap(Tap(userInfo: push(), action: "track"))
        XCTAssertEqual([track.notificationId, track.buttonId, track.url?.absoluteString], ["n-1", "track", "https://example.com/track"])
        let later = try XCTUnwrap(Tap(userInfo: push(), action: "later"))
        XCTAssertEqual([later.notificationId, later.buttonId, later.url?.absoluteString], ["n-1", "later", nil])
        XCTAssertNil(Tap(userInfo: push(), action: UNNotificationDismissActionIdentifier), "a dismissal is not an event")
        let bare = try XCTUnwrap(Tap(userInfo: ["source": "pushpilot", "url": ""], action: UNNotificationDefaultActionIdentifier))
        XCTAssertNil(bare.notificationId)
        XCTAssertNil(bare.url)
    }

    /// Links go to the app's handler when one is set, otherwise to the system; other pushes are left alone.
    func testLinkHandlerOverridesTheSystem() {
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-1"), actionIdentifier: UNNotificationDefaultActionIdentifier))
        drain()
        XCTAssertEqual(systemOpened, [URL(string: "myapp://orders/42")!])

        var handled: [URL] = []
        PushPilot.setLinkHandler { handled.append($0) }
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-2"), actionIdentifier: "track"))
        drain()
        XCTAssertEqual(handled, [URL(string: "https://example.com/track")!])
        XCTAssertEqual(systemOpened.count, 1, "the handler replaces the system")

        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-3"), actionIdentifier: "later"), "a button without a link opens nothing")
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-4"), actionIdentifier: UNNotificationDismissActionIdentifier))
        XCTAssertFalse(PushPilot.handleNotificationTap(userInfo: ["source": "other", "url": "https://x.io"],
                                                       actionIdentifier: UNNotificationDefaultActionIdentifier))
        drain()
        XCTAssertEqual(handled.count, 1)
    }

    /// The plain-data call records the click with its button; the same tap forwarded again counts once.
    func testTapForwardedTwiceCountsOnce() throws {
        PushPilot.initialize(sdkKey: "pk_test")
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-9"), actionIdentifier: "track"))
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-9"), actionIdentifier: "track"))
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-9"), actionIdentifier: UNNotificationDefaultActionIdentifier))
        drain()
        let events = try XCTUnwrap(engine?.state.events)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["notification_id"], .string("n-9"))
        XCTAssertEqual(events.first?["button_id"], .string("track"))
        XCTAssertEqual(systemOpened, [URL(string: "https://example.com/track")!])
    }

    /// A tap that launches a killed app, before the app calls initialize: the SDK starts from the saved key,
    /// queues the click on disk, and opens the link once, with the handler the app set during launch.
    func testKilledAppTap() throws {
        saved.config = SavedConfig(sdkKey: "pk_saved", baseUrl: PushPilot.defaultBaseUrl)
        var handled: [URL] = []
        PushPilot.setLinkHandler { handled.append($0) } // as in didFinishLaunching
        XCTAssertTrue(PushPilot.handleNotificationTap(userInfo: push("n-cold"), actionIdentifier: UNNotificationDefaultActionIdentifier))
        drain()
        XCTAssertEqual(storage.state?.events?.count, 1, "the click is on disk before initialize")
        XCTAssertEqual(handled, [URL(string: "myapp://orders/42")!])
        XCTAssertEqual(systemOpened, [])

        PushPilot.initialize(sdkKey: "pk_saved")
        _ = PushPilot.handleNotificationTap(userInfo: push("n-cold"), actionIdentifier: UNNotificationDefaultActionIdentifier)
        PushPilot.queue.sync { clock.advance(Engine.coalesceDelay) }
        drain()
        XCTAssertEqual(handled.count, 1, "opened once")
        let sent = network.all.first { $0.url.hasSuffix("/events/") }
        XCTAssertEqual(sent?.sdkKey, "pk_saved", "the click is sent")
    }

    /// With no saved key and no initialize yet, the click waits in memory and the system opens the link once.
    func testTapBeforeAnyInitialize() {
        _ = PushPilot.handleNotificationTap(userInfo: push("n-early"), actionIdentifier: UNNotificationDefaultActionIdentifier)
        drain()
        XCTAssertNil(engine)
        XCTAssertEqual(systemOpened.count, 1)
        PushPilot.initialize(sdkKey: "pk_test")
        PushPilot.queue.sync {}
        XCTAssertEqual(engine?.state.events?.count, 1)
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
